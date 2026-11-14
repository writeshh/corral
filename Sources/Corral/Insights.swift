import Network
import SwiftUI

/// Receives dumps from Symfony VarDumper's ServerDumper on 127.0.0.1:9912: one base64 line per dump.
/// Nothing leaves the Mac. The window keeps the newest 1000 dumps in memory.
@MainActor
final class Insights: ObservableObject {
    static let limit = 1000

    @Published private(set) var dumps: [Corral.Dump] = []
    @Published var error: String?
    private var listener: NWListener?
    private nonisolated let queue = DispatchQueue(label: "dev.corral.dumps")

    init() {
        if Corral().config.dumps { start() }
    }

    var listening: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(Corral.dumpPort))!)
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection, Data())
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor in
                    self?.error = "Corral cannot receive dumps on port \(Corral.dumpPort): \(error.localizedDescription). Stop other dump servers, such as php artisan dump-server."
                    self?.stop()
                    // Without a listener, sites must print dumps on the page again, so the setting goes off too.
                    DispatchQueue.global().async { let c = Corral(); if c.config.dumps { c.config.dumps = false; try? c.apply() } }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            objectWillChange.send()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        objectWillChange.send()
    }

    func clear() { dumps = [] }

    private nonisolated func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            var buffer = buffer + (data ?? Data())
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                self?.decode(line)
            }
            if done || error != nil { connection.cancel() } else { self?.receive(connection, buffer) }
        }
    }

    /// A new Corral reads config.json, so this queue never shares an instance with the app's work queue.
    private nonisolated func decode(_ line: String) {
        let result = Result { try Corral().decodeDump(line) }
        Task { @MainActor in
            switch result {
            case .success(let dump): self.dumps = Array(([dump] + self.dumps).prefix(Self.limit))
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}

/// The selected log file and what the window shows of it.
@MainActor
final class LogState: ObservableObject {
    /// The view shows the last line. Not @Published: it changes while the user scrolls, and must not redraw.
    var atEnd = true
    // Saved, so the choice survives a tab switch (SwiftUI makes a new LogsView) and a restart.
    @Published var site = UserDefaults.standard.string(forKey: "logSite") ?? "" { // "" = Corral's own logs only
        didSet { UserDefaults.standard.set(site, forKey: "logSite") }
    }
    @Published var file = UserDefaults.standard.string(forKey: "logFile") ?? "" {
        didSet { UserDefaults.standard.set(file, forKey: "logFile") }
    }
    @Published var picking = false // the site search popover is open
    @Published var query = ""
    var browser: String? // bundle id of the browser used last
    var browserHost = "" // the host the browser showed at the last check, so a manual pick stays until the browser moves

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id, Corral.browsers.contains(where: { $0.id == id }) { self?.browser = id } }
        }
    }
    @Published private(set) var text = "" { didSet { entries = LogEntry.parse(text, root: root) } }
    @Published private(set) var entries: [LogEntry] = []
    /// The folder of the selected site. Paths below it show without it.
    var root = "" { didSet { if root != oldValue { entries = LogEntry.parse(text, root: root) } } }
    private var cleared: [String: Int] = [:] // path -> file size when the user clicked Clear
    private var timer: Timer?

    /// Reads the file again every 2 seconds while the window shows it, like tail -f.
    func follow() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }

    func unfollow() { timer?.invalidate(); timer = nil }

    func reload() {
        guard !file.isEmpty else { text = ""; return }
        let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        let start = cleared[file].flatMap { $0 <= size ? $0 : nil } ?? 0 // a file that got shorter was rotated
        let tail = Corral.tail(file, bytes: UInt64(min(size - start, 128 * 1024)))
        if tail != text { text = tail }
    }

    func clear() {
        cleared[file] = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        reload()
    }
}

extension Corral.Dump {
    /// Colors for the SGR codes that dumpDecoder gives each token type. System colors follow light and dark mode.
    static let colors: [Int: Color] = [31: .blue, 32: .orange, 33: .green, 34: .cyan, 35: .secondary, 36: .purple, 37: .teal, 90: .blue]

    /// The dump text with its color codes turned into colors. Hyperlink codes (OSC 8) are dropped.
    var styled: AttributedString {
        var out = AttributedString(), color: Color?, rest = Substring(text)
        func add(_ s: Substring) { var piece = AttributedString(s); piece.foregroundColor = color; out += piece }
        while let esc = rest.firstIndex(of: "\u{1B}") {
            add(rest[..<esc])
            rest = rest[rest.index(after: esc)...]
            if rest.first == "]" {
                rest = rest.range(of: "\u{1B}\\").map { rest[$0.upperBound...] } ?? ""
            } else if rest.first == "[", let m = rest.firstIndex(of: "m") {
                color = rest[rest.index(after: rest.startIndex)..<m].split(separator: ";").last.flatMap { Int($0) }.flatMap { Self.colors[$0] }
                rest = rest[rest.index(after: m)...]
            }
        }
        add(rest)
        return out
    }
}

struct DumpsView: View {
    @ObservedObject var model: Model
    @ObservedObject var insights: Insights

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Send dump() to Corral", isOn: Binding(get: { model.snap.dumps && insights.listening }, set: setDumps)).toggleStyle(CorralToggleStyle(showsLabel: true))
                    .help("Sites send dump() and dd() output here, not into the page. Uses Symfony VarDumper's server mode on port \(String(Corral.dumpPort)).")
                Spacer()
                Text("\(insights.dumps.count) of \(Insights.limit)").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: insights.clear).disabled(insights.dumps.isEmpty).help("Remove the dumps from this list.")
            }
            .padding(10)
            if let error = insights.error {
                Banner(error: true, title: error, dismiss: { insights.error = nil }).padding(.horizontal, 10).padding(.bottom, 10)
            }
            Divider()
            if insights.dumps.isEmpty {
                ContentUnavailableView("No dumps yet", systemImage: "ladybug", description: Text(model.snap.dumps
                    ? "Call dump() or dd() in a Laravel or Symfony site."
                    : "Turn on \"Send dump() to Corral\" first."))
                    .frame(maxHeight: .infinity)
            } else {
                List(insights.dumps) { dump in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            request(dump.request)
                            Spacer()
                            Text(dump.time.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let colon = dump.source.lastIndex(of: ":") {
                            let file = String(dump.source[..<colon])
                            Button((dump.source as NSString).abbreviatingWithTildeInPath) { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
                                .buttonStyle(.link).font(.caption).lineLimit(1).truncationMode(.head)
                                .help("Open \((file as NSString).lastPathComponent)")
                        }
                        Text(dump.styled).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(Color.canvas, in: .rect(cornerRadius: 8))
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// "GET /orders" as a method badge and a path. A command line (dump from artisan or a script) gets a terminal icon.
    @ViewBuilder private func request(_ request: String) -> some View {
        let parts = request.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(parts[0]) {
            Text(parts[0]).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
            Text(parts[1]).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        } else {
            Label(request.isEmpty ? "Unknown request" : request, systemImage: "terminal")
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
        }
    }

    private func setDumps(_ on: Bool) {
        if on { insights.start() } else { insights.stop() }
        model.run(on ? "Sending dumps to Corral" : "Sending dumps to the page") { c in c.config.dumps = on; try c.apply() }
    }
}

/// One entry of a log file: when, how bad, and what. Lines without a time stamp belong to the entry before them.
struct LogEntry: Identifiable, Equatable {
    enum Level: String { case plain = "", info = "Info", notice = "Notice", warning = "Warning", error = "Error" }

    var id = 0
    var time = ""          // HH:mm:ss in local time, or empty
    var stamp = ""         // the time stamp as the file has it, for the tooltip
    var level = Level.plain
    var message = ""       // no HTML tags; `code` marks what was in <code>
    var detail: [String] = [] // stack frames and other lines without a time stamp
    var count = 1          // equal entries that follow each other show as one

    private static let levels: [String: Level] = [
        "debug": .info, "info": .info, "notice": .notice, "warning": .warning, "warn": .warning, "deprecated": .warning,
        "error": .error, "critical": .error, "crit": .error, "alert": .error, "emergency": .error, "emerg": .error,
        "fatal error": .error, "parse error": .error,
    ]

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss 'UTC'"
        return f
    }()

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Reads Laravel ("[stamp] local.ERROR: …"), PHP and WordPress ("[stamp UTC] PHP Notice: …"), nginx ("stamp [error] …")
    /// and PHP-FPM ("[stamp] NOTICE: …") logs. `root` is the site folder: paths below it show without it.
    static func parse(_ text: String, root: String = "") -> [LogEntry] {
        var entries: [LogEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = Substring(line), stamp: Substring?
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"), line.distance(from: line.startIndex, to: close) <= 40,
               line[..<close].contains(/\d\d:\d\d:\d\d/) {
                stamp = line[line.index(after: line.startIndex)..<close]
                rest = line[line.index(after: close)...]
            } else if line.prefix(19).wholeMatch(of: /\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d/) != nil {
                stamp = line.prefix(19)
                rest = line.dropFirst(19)
            }
            guard let stamp else {
                // A stack frame or a wrapped line. The first lines of a tail can have no entry before them.
                if entries.isEmpty { entries.append(LogEntry(message: clean(rest, root))) } else { entries[entries.count - 1].detail.append(clean(rest, root)) }
                continue
            }
            var entry = LogEntry(stamp: String(stamp))
            if stamp.hasSuffix("UTC"), let date = utc.date(from: String(stamp)) {
                entry.time = local.string(from: date)
            } else if let match = stamp.firstMatch(of: /\d\d:\d\d:\d\d/) {
                entry.time = String(match.output)
            }
            rest = rest.drop { $0 == " " }
            // "local.ERROR: ", "NOTICE: ", "[error] 401#0: ", "PHP Fatal error:  "
            if let m = rest.prefixMatch(of: #/(?:[A-Za-z_]+\.)?(DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY): /#) {
                entry.level = levels[m.1.lowercased()] ?? .plain
                rest = rest[m.range.upperBound...]
            } else if let m = rest.prefixMatch(of: #/\[(debug|info|notice|warn|error|crit|alert|emerg)\] (?:\d+#\d+: )?/#) {
                entry.level = levels[String(m.1)] ?? .plain
                rest = rest[m.range.upperBound...]
            } else if let m = rest.prefixMatch(of: /PHP (Notice|Warning|Deprecated|Fatal error|Parse error):\s+/) {
                entry.level = levels[m.1.lowercased()] ?? .plain
                rest = rest[m.range.upperBound...]
            }
            entry.message = clean(rest, root)
            entries.append(entry)
        }
        // Equal entries that follow each other become one, with a count and the time of the last one.
        var folded: [LogEntry] = []
        for entry in entries {
            if let last = folded.last, last.level == entry.level, last.message == entry.message, last.detail == entry.detail {
                folded[folded.count - 1].count += 1
                folded[folded.count - 1].time = entry.time
                folded[folded.count - 1].stamp = entry.stamp
            } else {
                folded.append(entry)
            }
        }
        for i in folded.indices { folded[i].id = i }
        return folded
    }

    /// Removes HTML tags and the site folder. "<code>x</code>" becomes "`x`", and " in file on line 12" becomes " file:12".
    private static func clean(_ text: Substring, _ root: String) -> String {
        var s = String(text)
        if !root.isEmpty { s = s.replacingOccurrences(of: root + "/", with: "") }
        s = s.replacing(/<\/?code>/, with: "`").replacing(/<[^>]+>/, with: "")
        for (entity, char) in [("&quot;", "\""), ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacing(#/ in (\S+) on line (\d+)$/#) { " \($0.1):\($0.2)" }
    }

    /// The message for display: inline code on a raised ground, and a file position at the end in the quiet ink.
    var styled: AttributedString {
        var out = AttributedString()
        for (i, part) in message.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString(String(part))
            if i % 2 == 1 { piece.backgroundColor = .surfaceRaised }
            out += piece
        }
        if let m = message.firstMatch(of: #/ \S+:\d+$/#), let range = out.range(of: String(m.output), options: .backwards) {
            out[range].foregroundColor = .inkMuted
        }
        return out
    }
}

struct LogsView: View {
    @ObservedObject var model: Model
    @ObservedObject var log: LogState
    @AppStorage("logFollowBrowser") private var followBrowser = false
    @AppStorage("logLevel") private var level = "" // the level filter: empty for all, "warning" or "error"

    private var sites: [(name: String, host: String)] {
        [("", "Corral only")] + model.snap.rows.filter { $0.site.proxy == nil }.map { ($0.site.name, $0.host) }
    }

    /// Picks the site that the browser shows. It acts when the browser moves to another host,
    /// so a site picked by hand stays until then. Hosts that match no site change nothing.
    private func syncBrowser() async {
        let bundle = log.browser ?? Corral.browsers.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty }?.id
        guard let bundle, let host = await Task.detached(operation: { Corral.browserHost(bundle) }).value, host != log.browserHost else { return }
        log.browserHost = host
        let corral = Corral()
        let row = model.snap.rows.first { $0.site.proxy == nil && corral.hostnames($0.site).contains { host == $0 || host.hasSuffix("." + $0) } }
        if let row { log.site = row.site.name }
    }

    private var site: Site? { model.snap.rows.first { $0.site.name == log.site }?.site }

    private var files: [String] { Corral().logFiles(site) }

    /// The file names for the menu. Two files with one name show their paths.
    private var fileOptions: [(String, String)] {
        let files = self.files, names = files.map { ($0 as NSString).lastPathComponent }
        return files.map { file in
            let name = (file as NSString).lastPathComponent
            return (file, names.filter { $0 == name }.count > 1 ? (file as NSString).abbreviatingWithTildeInPath : name)
        }
    }

    private var shown: [LogEntry] {
        level.isEmpty ? log.entries : log.entries.filter { $0.level.rawValue.lowercased() == level }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The label of Follow Browser goes first when the window is narrow.
            ViewThatFits(in: .horizontal) {
                toolbar(compact: false)
                toolbar(compact: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(Color.border).frame(height: 1)
            let shown = self.shown
            if shown.isEmpty {
                EmptyState(symbol: "doc.text", title: log.entries.isEmpty ? "Nothing logged" : "No \(level) in this file",
                           text: log.entries.isEmpty ? "New lines show here while the file grows." : "Choose All to see the other lines.") { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                // New lines scroll into view only while the last line shows. A user who scrolled up to read stays there.
                GeometryReader { viewport in
                    let height = viewport.size.height
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(shown) { LogLine(entry: $0) }
                            }
                            .padding(.vertical, 8)
                            Color.clear.frame(height: 1).id("end")
                                .onGeometryChange(for: Bool.self) { $0.frame(in: .named("log")).minY <= height + 40 } action: { log.atEnd = $0 }
                        }
                        .coordinateSpace(name: "log")
                        .onAppear { proxy.scrollTo("end") }
                        .onChange(of: log.entries) { if log.atEnd { proxy.scrollTo("end") } }
                        .onChange(of: log.file) { log.atEnd = true; proxy.scrollTo("end") }
                        .onChange(of: level) { log.atEnd = true; proxy.scrollTo("end") }
                    }
                }
                .background(Color.canvas)
            }
        }
        .buttonStyle(CorralButtonStyle())
        .onAppear { log.root = site?.path ?? ""; if !files.contains(log.file) { log.file = files.first ?? "" }; log.follow() }
        .onDisappear(perform: log.unfollow)
        .task(id: followBrowser) {
            log.browserHost = ""
            while followBrowser && !Task.isCancelled {
                await syncBrowser()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: log.site) { log.root = site?.path ?? ""; log.file = files.first ?? "" }
        .onChange(of: log.file) { log.reload() }
    }

    /// Site, file and level on the left. The actions of the view on the right.
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { log.picking = true } label: {
                HStack(spacing: 6) {
                    Text(sites.first { $0.name == log.site }?.host ?? "Corral only").lineLimit(1).truncationMode(.middle).frame(maxWidth: 170).fixedSize()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.inkMuted)
                }
            }
            .popover(isPresented: $log.picking, arrowEdge: .bottom) { SitePicker(sites: sites, log: log) }
            .accessibilityLabel("Site")
            ChoiceMenu(title: "File", selection: $log.file, options: fileOptions)
                .help((log.file as NSString).abbreviatingWithTildeInPath)
            Tabs(items: [("", "All", ""), ("warning", "Warnings", ""), ("error", "Errors", "")], selection: $level,
                 badges: ["error": log.entries.filter { $0.level == .error }.reduce(0) { $0 + $1.count }])
            Spacer(minLength: 8)
            Button { followBrowser.toggle() } label: {
                if compact { Label("Follow Browser", systemImage: "safari").labelStyle(.iconOnly) } else { Label("Follow Browser", systemImage: "safari") }
            }
            .buttonStyle(CorralButtonStyle(quiet: true, active: followBrowser))
            .accessibilityValue(followBrowser ? "On" : "Off")
            .help("Show the logs of the site in your browser. Safari, Chrome, Brave, Edge, Arc, Dia and Vivaldi. macOS asks once to let Corral control the browser.")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log.file)]) } label: { Image(systemName: "folder") }
                .buttonStyle(CorralButtonStyle(quiet: true))
                .disabled(log.file.isEmpty)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            Button("Clear", action: log.clear).disabled(log.text.isEmpty).help("Hide the lines up to now. The file does not change.")
        }
    }
}

/// One log entry in the well: the time, the level as a word, the message, and a count for equal entries.
struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.time).foregroundStyle(Color.inkFaint).frame(width: 60, alignment: .leading).help(entry.stamp)
            Text(entry.level.rawValue).fontWeight(.semibold)
                .foregroundStyle(entry.level == .error ? Color.danger : entry.level == .warning ? Color.warning : Color.inkMuted)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.styled)
                if !entry.detail.isEmpty { Text(entry.detail.joined(separator: "\n")).foregroundStyle(Color.inkMuted) }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.count > 1 {
                Text("×\(entry.count)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.warning)
                    .accessibilityLabel("\(entry.count) times")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(3)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

/// A site list with a search field. A menu with 100+ sites is too long to scan.
/// Return picks the first match.
struct SitePicker: View {
    let sites: [(name: String, host: String)]
    @ObservedObject var log: LogState
    @FocusState private var focused: Bool

    private var matches: [(name: String, host: String)] {
        log.query.isEmpty ? sites : sites.filter { $0.host.localizedCaseInsensitiveContains(log.query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sites", text: $log.query)
                .designField()
                .focused($focused)
                .onSubmit { if let first = matches.first { pick(first.name) } }
                .padding(8)
            Rectangle().fill(Color.border).frame(height: 1)
            List(matches, id: \.name) { site in
                Button { pick(site.name) } label: {
                    HStack {
                        Text(site.host)
                        Spacer()
                        if site.name == log.site { Image(systemName: "checkmark") }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if matches.isEmpty { Text("No match").foregroundStyle(.secondary) } }
        }
        .frame(width: 300, height: 360)
        .designSurface()
        .onAppear { log.query = ""; focused = true }
    }

    private func pick(_ name: String) {
        log.site = name
        log.picking = false
    }
}
