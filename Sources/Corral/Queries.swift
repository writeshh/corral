import SwiftUI

/// One web request and the SQL queries it ran, from logs/queries.jsonl.
struct QueryRequest: Decodable, Identifiable {
    struct Query: Decodable, Hashable {
        let sql: String
        let ms: Double
        let caller: String?
        let bindings: [String?]?

        /// The SQL with each ? replaced by its value, so it can run in a database client as is.
        // ponytail: a ? inside a string literal also gets a value. Rare in ORM queries.
        var filled: String {
            guard var values = bindings, !values.isEmpty else { return sql }
            var out = ""
            for c in sql {
                if c == "?", !values.isEmpty {
                    let v = values.removeFirst()
                    out += v.map { Double($0) != nil ? $0 : "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
                } else { out.append(c) }
            }
            return out
        }
    }

    let time: Double
    let method: String
    let url: String
    let status: Int?
    let queries: [Query]
    var id: String { "\(time) \(url)" }
    var totalMs: Double { queries.reduce(0) { $0 + $1.ms } }
    /// Queries that ran more than once with the same SQL: often an N+1 problem.
    var repeated: Int { queries.count - Set(queries.map(\.sql)).count }
}

extension Corral {
    var queriesScript: String { conf + "/queries.php" }
    var queryLog: String { logs + "/queries.jsonl" }

    /// The newest requests first. Lines that do not decode (a write in progress) are skipped.
    static func queryRequests(_ text: String) -> [QueryRequest] {
        text.split(separator: "\n").reversed().compactMap { try? JSONDecoder().decode(QueryRequest.self, from: Data($0.utf8)) }
    }

    /// The auto_prepend_file for "Record queries". It runs before the site's own code in every PHP-FPM request.
    /// Laravel: a listener for QueryExecuted. WordPress: SAVEQUERIES, read at shutdown. Other code: nothing is recorded.
    /// At shutdown, a request with queries appends one JSON line to logs/queries.jsonl. Nothing leaves the Mac.
    var queriesPHP: String {
        let log = queryLog.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return #"""
        <?php
        // Written by Corral for Insights > Queries. Turn it off there.
        if (PHP_SAPI === 'fpm-fcgi') (static function () {
            $queries = [];
            $start = microtime(true);
            $caller = static function () {
                foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 60) as $f) {
                    if (isset($f['file']) && !str_contains($f['file'], '/vendor/') && $f['file'] !== __FILE__) return $f['file'] . ':' . $f['line'];
                }
                return null;
            };
            // ponytail: Laravel has no hook before it boots, so this autoloader waits for its event dispatcher, adds
            // the listener, and removes itself. Without Laravel it stays and returns at once. A C extension (like Herd's) could hook PDO.
            $hook = static function () use (&$hook, &$queries, $caller) {
                if (!class_exists('Illuminate\Foundation\Application', false)) return;
                $app = \Illuminate\Container\Container::getInstance();
                if (!$app->bound('events')) return;
                spl_autoload_unregister($hook);
                $app['events']->listen('Illuminate\Database\Events\QueryExecuted', static function ($e) use (&$queries, $caller) {
                    $bindings = array_map(static fn ($b) => match (true) {
                        $b === null => null,
                        $b instanceof \DateTimeInterface => $b->format('Y-m-d H:i:s'),
                        is_bool($b) => $b ? '1' : '0',
                        is_scalar($b) || $b instanceof \Stringable => (string) $b,
                        default => get_debug_type($b),
                    }, $e->bindings);
                    $queries[] = ['sql' => $e->sql, 'bindings' => array_values($bindings), 'ms' => round($e->time, 2), 'caller' => $caller()];
                });
            };
            spl_autoload_register($hook, true, true);
            if (!defined('SAVEQUERIES')) define('SAVEQUERIES', true);

            register_shutdown_function(static function () use (&$queries, &$hook, $start) {
                spl_autoload_unregister($hook);
                global $wpdb;
                foreach (isset($wpdb->queries) && is_array($wpdb->queries) ? $wpdb->queries : [] as $q) {
                    // [sql, seconds, "caller, caller, ..."]: the last two callers name the code that ran the query.
                    $queries[] = ['sql' => $q[0], 'ms' => round($q[1] * 1000, 2), 'caller' => implode(', ', array_slice(explode(', ', (string) ($q[2] ?? '')), -2))];
                }
                if (!$queries) return;
                $log = '\#(log)';
                if (@filesize($log) > 20 << 20) @file_put_contents($log, ''); // keep the file small: start again at 20 MB
                $line = json_encode([
                    'time' => $start, 'method' => $_SERVER['REQUEST_METHOD'] ?? '', 'status' => http_response_code() ?: null,
                    'url' => ($_SERVER['HTTP_HOST'] ?? '') . ($_SERVER['REQUEST_URI'] ?? ''), 'queries' => $queries,
                ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);
                if ($line !== false) @file_put_contents($log, $line . "\n", FILE_APPEND | LOCK_EX);
            });
        })();

        """#
    }
}

/// The requests that the Queries tab shows. Reads the end of the log every 2 seconds while the tab is open.
@MainActor
final class QueryLog: ObservableObject {
    static let limit = 200
    @Published private(set) var requests: [QueryRequest] = []
    private let path = Corral().queryLog
    private var cleared = 0 // file size at the last Clear
    private var timer: Timer?

    func follow() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }

    func unfollow() { timer?.invalidate(); timer = nil }

    func reload() {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if cleared > size { cleared = 0 } // the file started again
        let text = Corral.tail(path, bytes: UInt64(min(size - cleared, 2 << 20)))
        let found = Array(Corral.queryRequests(text).prefix(Self.limit))
        if found.map(\.id) != requests.map(\.id) { requests = found }
    }

    func clear() {
        cleared = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        reload()
    }
}

struct QueriesView: View {
    @ObservedObject var model: Model
    @StateObject private var log = QueryLog()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Record queries", isOn: Binding(get: { model.snap.queries }, set: setQueries))
                    .help("Laravel and WordPress sites record each SQL query, with its time and the code that ran it.")
                Spacer()
                Text("\(log.requests.count) requests").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: log.clear).disabled(log.requests.isEmpty)
            }
            .padding(10)
            Divider()
            if log.requests.isEmpty {
                ContentUnavailableView("No queries yet", systemImage: "cylinder.split.1x2", description: Text(model.snap.queries
                    ? "Open a page of a Laravel or WordPress site."
                    : "Turn on \"Record queries\" first."))
                    .frame(maxHeight: .infinity)
            } else {
                List(log.requests) { request in
                    DisclosureGroup { ForEach(Array(request.queries.enumerated()), id: \.offset) { row($0.element) } } label: { header(request) }
                }
            }
        }
        .onAppear(perform: log.follow)
        .onDisappear(perform: log.unfollow)
    }

    private func header(_ r: QueryRequest) -> some View {
        HStack(spacing: 6) {
            Text(r.method).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule)
            Text(r.url).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if r.repeated > 0 {
                Text("\(r.repeated) repeated").font(.caption).foregroundStyle(.orange)
                    .help("Queries with the same SQL ran more than once. This is often an N+1 problem.")
            }
            Text("\(r.queries.count) \(r.queries.count == 1 ? "query" : "queries") · \(r.totalMs.formatted(.number.precision(.fractionLength(1)))) ms")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: r.time).formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func row(_ q: QueryRequest.Query) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(q.filled).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(q.ms.formatted(.number.precision(.fractionLength(2)))) ms").font(.caption.monospacedDigit())
                    .foregroundStyle(q.ms >= 100 ? .red : .secondary)
            }
            if let caller = q.caller, !caller.isEmpty {
                // Laravel gives file:line of the first frame outside vendor/. WordPress gives function names.
                if let colon = caller.lastIndex(of: ":"), caller.hasPrefix("/") {
                    Button((caller as NSString).abbreviatingWithTildeInPath) { NSWorkspace.shared.open(URL(fileURLWithPath: String(caller[..<colon]))) }
                        .buttonStyle(.link).font(.caption).lineLimit(1).truncationMode(.head)
                } else {
                    Text(caller).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func setQueries(_ on: Bool) {
        model.run(on ? "Recording queries" : "Stopping query recording") { c in c.config.queries = on; try c.apply() }
    }
}
