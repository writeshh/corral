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

    /// An outgoing HTTP call: Laravel's HTTP client, or wp_remote_* in WordPress. status nil = the connection failed.
    struct HTTPCall: Decodable, Hashable {
        let method: String
        let url: String
        let status: Int?
        let ms: Double?
        let error: String?
    }

    /// A Laravel cache event: hit, miss, write, or forget.
    struct CacheOp: Decodable, Hashable {
        let op: String
        let key: String
    }

    /// A Laravel queue event in this request: queued, processed (a sync job), or failed.
    struct Job: Decodable, Hashable {
        let event: String
        let job: String
        let queue: String?
        let error: String?
    }

    let time: Double
    let method: String
    let url: String
    let status: Int?
    let queries: [Query]
    let http: [HTTPCall]?
    let cache: [CacheOp]?
    let jobs: [Job]?
    var id: String { "\(time) \(url)" }
    var totalMs: Double { queries.reduce(0) { $0 + $1.ms } }
    /// Queries that ran more than once with the same SQL: often an N+1 problem.
    var repeated: Int { queries.count - Set(queries.map(\.sql)).count }

    /// "12 queries · 2 HTTP · 5 cache (3 hits) · 1 job"
    var counts: String {
        var parts = queries.isEmpty ? [] : ["\(queries.count) \(queries.count == 1 ? "query" : "queries") · \(totalMs.formatted(.number.precision(.fractionLength(1)))) ms"]
        if let http, !http.isEmpty { parts.append("\(http.count) HTTP") }
        if let cache, !cache.isEmpty { parts.append("\(cache.count) cache (\(cache.filter { $0.op == "hit" }.count) hits)") }
        if let jobs, !jobs.isEmpty { parts.append("\(jobs.count) \(jobs.count == 1 ? "job" : "jobs")") }
        return parts.joined(separator: " · ")
    }
}

extension Corral {
    var queriesScript: String { conf + "/queries.php" }
    var queryLog: String { logs + "/queries.jsonl" }

    /// The newest requests first. Lines that do not decode (a write in progress) are skipped.
    static func queryRequests(_ text: String) -> [QueryRequest] {
        text.split(separator: "\n").reversed().compactMap { try? JSONDecoder().decode(QueryRequest.self, from: Data($0.utf8)) }
    }

    /// The auto_prepend_file for "Record requests" (config key `queries`). It runs before the site's code in every PHP-FPM request.
    /// Laravel: listeners for queries, HTTP client calls, cache events and queue events. WordPress: SAVEQUERIES, read at
    /// shutdown, and the HTTP API hooks. Other code: nothing is recorded. A request with something to show appends one JSON
    /// line to logs/queries.jsonl. Nothing leaves the Mac. Queue workers (artisan queue:work) run in the CLI and are not recorded.
    var queriesPHP: String {
        let log = queryLog.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return #"""
        <?php
        // Written by Corral for Insights > Requests. Turn it off there.
        if (PHP_SAPI === 'fpm-fcgi') (static function () {
            $queries = []; $http = []; $cache = []; $jobs = []; $started = [];
            $start = microtime(true);
            $caller = static function () {
                foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 60) as $f) {
                    if (isset($f['file']) && !str_contains($f['file'], '/vendor/') && $f['file'] !== __FILE__) return $f['file'] . ':' . $f['line'];
                }
                return null;
            };
            // ponytail: Laravel has no hook before it boots, so this autoloader waits for its event dispatcher, adds
            // the listeners, and removes itself. Without Laravel it stays and returns at once. A C extension (like Herd's) could hook PDO.
            $hook = static function () use (&$hook, &$queries, &$http, &$cache, &$jobs, $caller) {
                if (!class_exists('Illuminate\Foundation\Application', false)) return;
                $app = \Illuminate\Container\Container::getInstance();
                if (!$app->bound('events')) return;
                spl_autoload_unregister($hook);
                $events = $app['events'];
                $events->listen('Illuminate\Database\Events\QueryExecuted', static function ($e) use (&$queries, $caller) {
                    $bindings = array_map(static fn ($b) => match (true) {
                        $b === null => null,
                        $b instanceof \DateTimeInterface => $b->format('Y-m-d H:i:s'),
                        is_bool($b) => $b ? '1' : '0',
                        is_scalar($b) || $b instanceof \Stringable => (string) $b,
                        default => get_debug_type($b),
                    }, $e->bindings);
                    $queries[] = ['sql' => $e->sql, 'bindings' => array_values($bindings), 'ms' => round($e->time, 2), 'caller' => $caller()];
                });
                $events->listen('Illuminate\Http\Client\Events\ResponseReceived', static function ($e) use (&$http) {
                    $seconds = $e->response->transferStats?->getTransferTime();
                    $http[] = ['method' => $e->request->method(), 'url' => $e->request->url(), 'status' => $e->response->status(),
                               'ms' => $seconds === null ? null : round($seconds * 1000, 1)];
                });
                $events->listen('Illuminate\Http\Client\Events\ConnectionFailed', static function ($e) use (&$http) {
                    $http[] = ['method' => $e->request->method(), 'url' => $e->request->url(), 'status' => null, 'error' => 'Connection failed'];
                });
                foreach (['CacheHit' => 'hit', 'CacheMissed' => 'miss', 'KeyWritten' => 'write', 'KeyForgotten' => 'forget'] as $class => $op) {
                    $events->listen('Illuminate\Cache\Events\\' . $class, static function ($e) use (&$cache, $op) { $cache[] = ['op' => $op, 'key' => (string) $e->key]; });
                }
                $events->listen('Illuminate\Queue\Events\JobQueued', static function ($e) use (&$jobs) {
                    $jobs[] = ['event' => 'queued', 'job' => is_object($e->job) ? get_class($e->job) : (string) $e->job,
                               'queue' => $e->connectionName . (isset($e->queue) && $e->queue ? ':' . $e->queue : '')];
                });
                $events->listen('Illuminate\Queue\Events\JobProcessed', static function ($e) use (&$jobs) {
                    $jobs[] = ['event' => 'processed', 'job' => $e->job->resolveName(), 'queue' => $e->connectionName];
                });
                $events->listen('Illuminate\Queue\Events\JobFailed', static function ($e) use (&$jobs) {
                    $jobs[] = ['event' => 'failed', 'job' => $e->job->resolveName(), 'queue' => $e->connectionName, 'error' => $e->exception->getMessage()];
                });
            };
            spl_autoload_register($hook, true, true);
            // A wp-config.php that defines SAVEQUERIES itself would warn "already defined", so then its own value counts.
            // WordPress also looks for wp-config.php one folder above the document root.
            $root = rtrim($_SERVER['DOCUMENT_ROOT'] ?? '', '/');
            $owns = false;
            foreach ([$root, dirname($root)] as $dir) {
                if ($root !== '' && is_file("$dir/wp-config.php")) {
                    $owns = (bool) preg_match('/^\s*define\s*\(\s*[\'"]SAVEQUERIES[\'"]/m', (string) @file_get_contents("$dir/wp-config.php"));
                    break;
                }
            }
            if (!$owns && !defined('SAVEQUERIES')) define('SAVEQUERIES', true);
            // WordPress reads hooks that exist before it loads (WP_Hook::build_preinitialized_hooks). pre_http_request
            // marks the start, http_api_debug the end of each wp_remote_* call.
            $GLOBALS['wp_filter']['pre_http_request'][-1000][] = ['accepted_args' => 3, 'function' => static function ($pre, $args, $url) use (&$started) {
                $started[$url][] = microtime(true);
                return $pre;
            }];
            $GLOBALS['wp_filter']['http_api_debug'][1000][] = ['accepted_args' => 5, 'function' => static function ($response, $context, $class, $args, $url) use (&$http, &$started) {
                $begin = isset($started[$url]) ? array_pop($started[$url]) : null;
                $error = is_object($response) && method_exists($response, 'get_error_message') ? $response->get_error_message() : null;
                $http[] = ['method' => $args['method'] ?? 'GET', 'url' => $url, 'status' => $error === null ? (int) ($response['response']['code'] ?? 0) : null,
                           'ms' => $begin === null ? null : round((microtime(true) - $begin) * 1000, 1), 'error' => $error];
            }];

            register_shutdown_function(static function () use (&$queries, &$http, &$cache, &$jobs, &$hook, $start) {
                spl_autoload_unregister($hook);
                global $wpdb;
                foreach (isset($wpdb->queries) && is_array($wpdb->queries) ? $wpdb->queries : [] as $q) {
                    // [sql, seconds, "caller, caller, ..."]: the last two callers name the code that ran the query.
                    $queries[] = ['sql' => $q[0], 'ms' => round($q[1] * 1000, 2), 'caller' => implode(', ', array_slice(explode(', ', (string) ($q[2] ?? '')), -2))];
                }
                if (!$queries && !$http && !$cache && !$jobs) return;
                $log = '\#(log)';
                if (@filesize($log) > 20 << 20) @file_put_contents($log, ''); // keep the file small: start again at 20 MB
                $line = json_encode([
                    'time' => $start, 'method' => $_SERVER['REQUEST_METHOD'] ?? '', 'status' => http_response_code() ?: null,
                    'url' => ($_SERVER['HTTP_HOST'] ?? '') . ($_SERVER['REQUEST_URI'] ?? ''),
                    'queries' => $queries, 'http' => $http, 'cache' => $cache, 'jobs' => $jobs,
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
                Toggle("Record requests", isOn: Binding(get: { model.snap.queries }, set: setQueries))
                    .help("Laravel and WordPress sites record their SQL queries and outgoing HTTP calls. Laravel sites also record cache and queue events.")
                Spacer()
                Text("\(log.requests.count) of \(QueryLog.limit)").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: log.clear).disabled(log.requests.isEmpty).help("Hide the requests up to now. The log file does not change.")
            }
            .padding(10)
            Divider()
            if log.requests.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "cylinder.split.1x2", description: Text(model.snap.queries
                    ? "Open a page of a Laravel or WordPress site."
                    : "Turn on \"Record requests\" first."))
                    .frame(maxHeight: .infinity)
            } else {
                List(log.requests) { request in
                    DisclosureGroup { details(request) } label: { header(request) }
                }
            }
        }
        .onAppear(perform: log.follow)
        .onDisappear(perform: log.unfollow)
    }

    /// Two lines: what the request was and how it ended, then what it did. The method and status columns have a
    /// fixed width, so every URL starts at the same place and the list reads as a table.
    private func header(_ r: QueryRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(r.method).font(.caption2.weight(.bold).monospaced()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            statusBadge(r.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.url).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: r.time).formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(r.counts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if r.repeated > 0 {
                        Text("\(r.repeated) repeated").font(.caption.weight(.medium)).foregroundStyle(.orange)
                            .help("Queries with the same SQL ran more than once. This is often an N+1 problem.")
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// A failed request must not look like a good one: 4xx orange, 5xx red as a filled badge, others quiet text.
    private func statusBadge(_ status: Int?) -> some View {
        let code = status ?? 0
        let color: Color = code >= 500 ? .red : code >= 400 ? .orange : .secondary
        return Text(status.map(String.init) ?? "–").font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(code >= 400 ? .white : color)
            .frame(width: 34)
            .padding(.vertical, 1)
            .background(code >= 400 ? AnyShapeStyle(color) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
            .accessibilityLabel(status.map { "Status \($0)" } ?? "No status")
    }

    @ViewBuilder private func details(_ r: QueryRequest) -> some View {
        if let http = r.http, !http.isEmpty {
            section("HTTP")
            ForEach(Array(http.enumerated()).map { ("http\($0.offset)", $0.element) }, id: \.0) { _, call in
                HStack(alignment: .firstTextBaseline) {
                    Text(call.method).font(.caption2.weight(.bold))
                    Text(call.url).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(call.status.map(String.init) ?? (call.error ?? "failed")).font(.caption.monospacedDigit())
                        .foregroundStyle((call.status ?? 500) >= 400 ? .red : .secondary)
                    if let ms = call.ms { Text("\(ms.formatted(.number.precision(.fractionLength(0)))) ms").font(.caption.monospacedDigit()).foregroundStyle(ms >= 1000 ? .red : .secondary) }
                }
            }
        }
        if let cache = r.cache, !cache.isEmpty {
            // One row for each key, with how often each event hit it, so a key read 50 times stands out.
            section("Cache")
            let keys = Dictionary(grouping: cache, by: \.key).sorted { $0.value.count > $1.value.count }
            // Every section has its own ids: rows of one request share a List, and equal ids would show the same row twice.
            ForEach(keys.map { ("cache:" + $0.key, $0.key, $0.value) }, id: \.0) { _, key, ops in
                HStack {
                    Text(key).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Dictionary(grouping: ops, by: \.op).sorted { $0.key < $1.key }.map { "\($0.value.count) \($0.key)" }.joined(separator: ", "))
                        .font(.caption.monospacedDigit()).foregroundStyle(ops.count > 3 ? .orange : .secondary)
                }
            }
        }
        if let jobs = r.jobs, !jobs.isEmpty {
            section("Jobs")
            ForEach(Array(jobs.enumerated()).map { ("job\($0.offset)", $0.element) }, id: \.0) { jobRow($0.1) }
        }
        if !r.queries.isEmpty {
            if r.http?.isEmpty == false || r.cache?.isEmpty == false || r.jobs?.isEmpty == false { section("Queries") }
            ForEach(Array(r.queries.enumerated()).map { ("query\($0.offset)", $0.element) }, id: \.0) { row($0.1) }
        }
    }

    private func jobRow(_ job: QueryRequest.Job) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(job.event).font(.caption2.weight(.bold)).foregroundStyle(job.event == "failed" ? Color.red : Color.primary)
            Text(job.job).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Text(job.error ?? job.queue ?? "").font(.caption).foregroundStyle(job.error == nil ? Color.secondary : Color.red).lineLimit(2)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
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
        model.run(on ? "Recording requests" : "Stopping request recording") { c in c.config.queries = on; try c.apply() }
    }
}
