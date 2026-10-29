import Network
import QuickLook
import SwiftUI

/// One caught message: an .eml file in <home>/mail. Quick Look renders it, so Corral parses only the headers.
struct MailMessage: Identifiable, Sendable {
    let url: URL
    let subject: String
    let from: String
    let to: String
    let inbox: String     // the SMTP user name, like Herd's inboxes. Corral's .env setup uses the site name.
    let date: Date
    var id: URL { url }

    init(url: URL) {
        self.url = url
        let start = (try? FileHandle(forReadingFrom: url)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 64 * 1024) }
        let headers = Self.headers(String(decoding: start ?? Data(), as: UTF8.self).components(separatedBy: "\r\n\r\n")[0])
        subject = headers["subject"].map(Self.decodeWords) ?? "(no subject)"
        from = headers["from"].map(Self.decodeWords) ?? ""
        to = headers["to"].map(Self.decodeWords) ?? ""
        inbox = headers["x-corral-inbox"] ?? ""
        date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Header names in lowercase. Folded lines (starting with a space or tab) continue the line before.
    static func headers(_ head: String) -> [String: String] {
        var out: [String: String] = [:], last = ""
        for line in head.components(separatedBy: "\r\n") {
            if line.first == " " || line.first == "\t", !last.isEmpty {
                out[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                last = line[..<colon].lowercased()
                out[last] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// RFC 2047 encoded words, for example =?utf-8?Q?Gr=C3=BC=C3=9Fe?= in a subject.
    static func decodeWords(_ value: String) -> String {
        value.replacing(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=(\s+(?==\?))?/) { m in
            let text = String(m.3)
            let bytes: Data? = m.2.uppercased() == "B" ? Data(base64Encoded: text) : {
                var data = Data(), chars = Array(text.utf8), i = 0
                while i < chars.count {
                    if chars[i] == UInt8(ascii: "="), i + 2 < chars.count, let b = UInt8(String(decoding: chars[i+1...i+2], as: UTF8.self), radix: 16) {
                        data.append(b); i += 3
                    } else {
                        data.append(chars[i] == UInt8(ascii: "_") ? UInt8(ascii: " ") : chars[i]); i += 1
                    }
                }
                return data
            }()
            return bytes.map { String(decoding: $0, as: UTF8.self) } ?? String(m.0)
        }
    }
}

/// A minimal SMTP server on 127.0.0.1:2525, Herd's mail port. It accepts every message and every login.
/// ponytail: no STARTTLS and no size limit. Local apps only; add Mailpit if people need its API or search.
@MainActor
final class MailServer: ObservableObject {
    static let port = 2525, limit = 1000

    @Published private(set) var messages: [MailMessage] = []
    @Published var error: String?
    private var listener: NWListener?
    private let dir: URL
    private nonisolated let queue = DispatchQueue(label: "dev.corral.mail")

    init() {
        let corral = Corral()
        dir = URL(fileURLWithPath: corral.home + "/mail")
        reload()
        if corral.config.mail { start() }
    }

    var listening: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(Self.port))!)
        params.allowLocalEndpointReuse = true
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let listener = try NWListener(using: params)
            let (dir, queue) = (dir, queue)
            listener.newConnectionHandler = { [weak self] connection in
                SMTPSession(connection, queue: queue) { inbox, data in
                    let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).eml"
                    try? (Data("X-Corral-Inbox: \(inbox)\r\n".utf8) + data).write(to: dir.appendingPathComponent(name))
                    Task { @MainActor in self?.reload() }
                }.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor in
                    self?.error = "Corral cannot receive mail on port \(Self.port): \(error.localizedDescription). Herd's mail service uses the same port."
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

    /// Newest first. Deletes the oldest files above the limit.
    func reload() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "eml" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // names start with the time in milliseconds
        for old in files.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: old) }
        messages = files.prefix(Self.limit).map(MailMessage.init)
    }

    func delete(_ message: MailMessage) {
        try? FileManager.default.removeItem(at: message.url)
        reload()
    }

    func clear() {
        for m in messages { try? FileManager.default.removeItem(at: m.url) }
        reload()
    }
}

/// One SMTP connection. Used only on MailServer's queue.
final class SMTPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let save: @Sendable (String, Data) -> Void
    private var buffer = Data(), message = Data()
    private var inData = false
    private var authLines = 0       // lines that the AUTH command still expects
    private var authLogin = false
    private var inbox = ""

    init(_ connection: NWConnection, queue: DispatchQueue, save: @escaping @Sendable (String, Data) -> Void) {
        self.connection = connection
        self.queue = queue
        self.save = save
    }

    func start() {
        connection.start(queue: queue)
        reply("220 corral ESMTP")
        receive()
    }

    private func reply(_ line: String) { connection.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in }) }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            if let data { self.buffer += data }
            while let newline = self.buffer.firstIndex(of: 10) {
                var line = Data(self.buffer[..<newline])
                self.buffer = Data(self.buffer[self.buffer.index(after: newline)...])
                if line.last == 13 { line.removeLast() }
                self.handle(line)
            }
            if done || error != nil { self.connection.cancel() } else { self.receive() }
        }
    }

    private func handle(_ line: Data) {
        if inData {
            if line == Data(".".utf8) {
                inData = false
                save(inbox, message)
                message = Data()
                reply("250 2.0.0 OK: queued")
            } else {
                message += (line.first == UInt8(ascii: ".") ? line.dropFirst() : line) + Data("\r\n".utf8) // undo dot-stuffing
            }
            return
        }
        let text = String(decoding: line, as: UTF8.self)
        if authLines > 0 {
            if authLogin && authLines == 2 { inbox = Self.base64(text) }
            if !authLogin { inbox = Self.plainUser(text) }
            authLines -= 1
            reply(authLines == 0 ? "235 2.7.0 Authentication successful" : "334 UGFzc3dvcmQ6")
            return
        }
        let words = text.split(separator: " ").map(String.init)
        switch words.first?.uppercased() ?? "" {
        case "EHLO": ["250-corral", "250-AUTH PLAIN LOGIN", "250-8BITMIME", "250 SMTPUTF8"].forEach(reply)
        case "HELO": reply("250 corral")
        case "MAIL", "RCPT", "NOOP": reply("250 2.0.0 OK")
        case "RSET": message = Data(); reply("250 2.0.0 OK")
        case "DATA": inData = true; reply("354 End data with <CR><LF>.<CR><LF>")
        case "AUTH" where words.count > 1 && words[1].uppercased() == "LOGIN":
            authLogin = true
            if words.count > 2 { inbox = Self.base64(words[2]); authLines = 1; reply("334 UGFzc3dvcmQ6") }
            else { authLines = 2; reply("334 VXNlcm5hbWU6") }
        case "AUTH":
            authLogin = false
            if words.count > 2 { inbox = Self.plainUser(words[2]); reply("235 2.7.0 Authentication successful") }
            else { authLines = 1; reply("334 ") }
        case "QUIT": reply("221 2.0.0 Bye"); connection.cancel()
        default: reply("502 5.5.2 Command not recognized")
        }
    }

    static func base64(_ s: String) -> String { Data(base64Encoded: s).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// AUTH PLAIN sends base64 of "authzid\0user\0password".
    static func plainUser(_ s: String) -> String {
        let parts = base64(s).split(separator: "\0", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : ""
    }
}

struct MailView: View {
    @ObservedObject var model: Model
    @ObservedObject var mail: MailServer
    @StateObject private var preview = MailPreview()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Catch mail on 127.0.0.1:\(MailServer.port)", isOn: Binding(get: { model.snap.mail }, set: setMail))
                Spacer()
                Text("\(mail.messages.count) of \(MailServer.limit)").font(.caption).foregroundStyle(.secondary)
                Button("Clear", action: mail.clear).disabled(mail.messages.isEmpty)
            }
            .padding(10)
            if let error = mail.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { mail.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            if mail.messages.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No mail yet").font(.headline)
                    Text("Send mail with SMTP to 127.0.0.1 port \(MailServer.port). In a Laravel site, use \"Send Mail to Corral\" in the site menu.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(mail.messages) { m in
                    Button { preview.url = m.url } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.subject).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(m.from) → \(m.to)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !m.inbox.isEmpty { Text(m.inbox).font(.caption2).foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Preview") { preview.url = m.url }
                        Button("Open in Mail") { NSWorkspace.shared.open(m.url) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
                        Divider()
                        Button("Delete") { mail.delete(m) }
                    }
                }
            }
        }
        .quickLookPreview($preview.url)
    }

    private func setMail(_ on: Bool) {
        if on { mail.start() } else { mail.stop() }
        model.run(nil) { c in c.config.mail = on; try c.save() }
    }
}

/// The message that Quick Look shows. @State is a macro that the Command Line Tools cannot expand.
final class MailPreview: ObservableObject { @Published var url: URL? }
