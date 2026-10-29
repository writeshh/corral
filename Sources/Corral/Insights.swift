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
    @Published var site = ""      // "" = Corral's own logs only
    @Published var file = ""
    @Published private(set) var text = ""
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

struct InsightsView: View {
    @ObservedObject var model: Model
    @ObservedObject var insights: Insights
    @ObservedObject var mail: MailServer
    @AppStorage("insightsTab") private var tab = "dumps"

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Dumps").tag("dumps")
                Text("Logs").tag("logs")
                Text("Mail").tag("mail")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(10)
            Divider()
            switch tab {
            case "logs": LogsView(model: model)
            case "mail": MailView(model: model, mail: mail)
            default: DumpsView(model: model, insights: insights)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct DumpsView: View {
    @ObservedObject var model: Model
    @ObservedObject var insights: Insights

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Send dump() to Corral", isOn: Binding(get: { model.snap.dumps }, set: setDumps))
                    .help("Sites send dump() and dd() output here, not into the page. Uses Symfony VarDumper's server mode on port \(Corral.dumpPort).")
                Spacer()
                Text("\(insights.dumps.count) of \(Insights.limit)").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: insights.clear).disabled(insights.dumps.isEmpty)
            }
            .padding(10)
            if let error = insights.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { insights.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            if insights.dumps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "ladybug").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No dumps yet").font(.headline)
                    Text(model.snap.dumps ? "Call dump() or dd() in a Laravel or Symfony site." : "Turn on \"Send dump() to Corral\" first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(insights.dumps) { dump in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(dump.request).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(dump.time.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text((dump.source as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Text(dump.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func setDumps(_ on: Bool) {
        if on { insights.start() } else { insights.stop() }
        model.run(on ? "Sending dumps to Corral" : "Sending dumps to the page") { c in c.config.dumps = on; try c.apply() }
    }
}

struct LogsView: View {
    @ObservedObject var model: Model
    @StateObject private var log = LogState()

    private var files: [String] {
        let corral = Corral()
        return corral.logFiles(model.snap.rows.first { $0.site.name == log.site }?.site)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Site", selection: $log.site) {
                    Text("Corral only").tag("")
                    ForEach(model.snap.rows.filter { $0.site.proxy == nil }) { Text($0.host).tag($0.site.name) }
                }
                .fixedSize()
                Picker("File", selection: $log.file) {
                    ForEach(files, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag($0) }
                }
                Button("Clear", action: log.clear).disabled(log.text.isEmpty).help("Hide the lines up to now. The file does not change.")
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log.file)]) }.disabled(log.file.isEmpty)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text.isEmpty ? "This file is empty." : log.text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(log.text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: log.text) { proxy.scrollTo("end") }
            }
        }
        .onAppear { if log.file.isEmpty { log.file = files.first ?? "" }; log.follow() }
        .onDisappear(perform: log.unfollow)
        .onChange(of: log.site) { log.file = files.first ?? "" }
        .onChange(of: log.file) { log.reload() }
    }
}
