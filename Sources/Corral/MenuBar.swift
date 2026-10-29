import ServiceManagement
import SwiftUI

/// What the panel shows. Built on the work queue after each job, then published on the main actor.
struct Snapshot: Sendable {
    struct Row: Identifiable, Sendable {
        let site: Site
        let host: String
        let url: URL
        let detail: String
        let php: String?
        let secured: Bool
        let isolated: String?
        var id: String { site.name }
    }

    var rows: [Row] = []
    var services: [(name: String, up: Bool)] = []
    var versions: [String] = []
    var globalPHP: String?
    var installed = true
    var ownsTest = false
    var home = ""
    var parked: [String] = []
    var links: [(name: String, path: String)] = []
    var proxies: [(name: String, url: String)] = []
    var certs: [(host: String, expires: Date?)] = []
    var managed: Set<String> = []          // PHP versions that Corral installed
    var iniPaths: [String: String] = [:]   // PHP version -> php.ini
    var ini: [String: [String: String]] = [:] // PHP version -> values of PHPSettings.keys
    var pools: [String: FpmPool] = [:]
    var loginItem = SMAppService.Status.notRegistered
    var tld = Config().tld
    var aliases: [String] = []
    var missing: [String] = []             // TLDs that do not resolve to Corral yet

    init() {}

    init(_ c: Corral) {
        let php = c.phpVersions()
        let tilde = NSHomeDirectory()
        let sites = c.sites()
        rows = sites.map { s in
            let shortPath = s.path.hasPrefix(tilde) ? "~" + s.path.dropFirst(tilde.count) : s.path
            let version = s.proxy == nil ? c.php(for: s, php) : nil
            return Row(site: s, host: c.host(s), url: c.url(s),
                       detail: s.proxy == nil ? shortPath : "Proxy to \(s.path)",
                       php: version, secured: c.config.secured.contains(s.name), isolated: c.config.isolated[s.name])
        }
        services = c.status().map { (name: $0.0, up: $0.1) }
        versions = Corral.sortVersions(php.keys)
        globalPHP = c.globalPHP(php)
        missing = c.resolverTLDs(sites).filter { !Corral.resolverIsCorral("/etc/resolver/" + $0) }
        installed = missing.isEmpty
        tld = c.config.tld
        aliases = c.config.aliases
        ownsTest = c.ownsTest
        home = c.home
        parked = c.config.parked
        links = c.config.links.sorted { $0.key < $1.key }.map { (name: $0.key, path: $0.value) }
        proxies = c.config.proxies.sorted { $0.key < $1.key }.map { (name: $0.key, url: $0.value) }
        certs = sites.filter { c.config.secured.contains($0.name) }.map { (host: c.host($0), expires: c.certExpiry(c.certPath($0))) }
        managed = Set(php.filter { c.isManaged($0.value) }.keys)
        iniPaths = Dictionary(uniqueKeysWithValues: php.map { ($0.key, c.iniPath($0.key, $0.value)) })
        for (v, path) in iniPaths {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            ini[v] = Dictionary(uniqueKeysWithValues: PHPSettings.keys.compactMap { k in Corral.iniValue(text, k).map { (k, $0) } })
            pools[v] = c.config.fpm[v] ?? FpmPool()
        }
        loginItem = SMAppService.mainApp.status
    }
}

@MainActor
final class Model: ObservableObject {
    @Published private(set) var snap = Snapshot()
    @Published private(set) var busy: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var filter = ""

    private let corral: Corral
    private let queue = DispatchQueue(label: "dev.corral.work") // every Corral call from the app runs here

    var running: Bool { snap.services.first?.up ?? false }

    private var watchdog: Timer?

    init(corral: Corral = Corral()) {
        self.corral = corral
        refresh()
        repair()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repair() }
        }
    }

    /// Starts the services that are down, if they ran before: after a login, or when a process stops.
    /// Like Herd's FpmRepair. The app is the only supervisor, so no LaunchAgent fights it.
    func repair() {
        guard busy == nil else { return }
        let corral = corral
        queue.async {
            guard corral.wantsRunning else { return }
            let down = corral.status().filter { !$0.1 }.map(\.0)
            guard !down.isEmpty else { return }
            var message: String?
            do { try corral.start() } catch { message = error.localizedDescription }
            let snap = Snapshot(corral)
            Task { @MainActor in
                self.snap = snap
                if let message { if self.error != message { self.error = message } }
                else { self.notice = "Restarted \(down.joined(separator: ", ")) at \(Date.now.formatted(date: .omitted, time: .shortened))." }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        run(nil) { _ in try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    func refresh() { run(nil) { _ in } }

    /// Runs slow work (downloads, process starts) off the main thread, then refreshes the panel.
    func run(_ label: String?, _ work: @escaping @Sendable (Corral) throws -> Void) {
        if label != nil { busy = label; error = nil }
        let corral = corral
        queue.async {
            var message: String?
            do { try work(corral) } catch { message = error.localizedDescription }
            let snap = Snapshot(corral)
            Task { @MainActor in
                self.snap = snap
                if label != nil { self.busy = nil }
                if let message { self.error = message }
            }
        }
    }

    func toggleServices() {
        if running { run("Stopping") { $0.stop() } } else { run("Starting") { try $0.start() } }
    }

    func park() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Park"
        panel.message = "Corral serves each subfolder as <folder>.\(snap.tld)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Parking") { c in
            if !c.config.parked.contains(url.path) { c.config.parked.append(url.path) }
            try c.apply()
        }
    }
}

struct CorralApp: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) } // no Dock icon when run from a terminal

    var body: some Scene {
        MenuBarExtra("Corral", systemImage: model.running ? "circle.hexagongrid.fill" : "circle.hexagongrid") {
            Panel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }
    }
}

// MARK: - Panel

struct Panel: View {
    @ObservedObject var model: Model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [Snapshot.Row] {
        model.filter.isEmpty ? model.snap.rows : model.snap.rows.filter { $0.host.localizedCaseInsensitiveContains(model.filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error { banner(error) }
            if let notice = model.notice { banner(notice, isError: false) }
            if !model.snap.installed { setupBanner }
            Divider().padding(.top, 10)
            sites
            Divider()
            footer
        }
        .frame(width: 360)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.snap.rows.map(\.id))
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.error)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Corral").font(.headline)
                    Text(model.busy.map { "\($0)…" } ?? (model.running ? "Running" : "Stopped"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
                if model.busy != nil { ProgressView().controlSize(.small) }
                Button(model.running ? "Stop" : "Start", action: model.toggleServices)
                    .buttonStyle(.borderedProminent)
                    .tint(model.running ? .secondary : .accentColor)
                    .controlSize(.regular)
                    .disabled(model.busy != nil)
            }
            HStack(spacing: 6) {
                ForEach(model.snap.services, id: \.name) { service in
                    ServiceChip(name: service.name, up: service.up)
                }
            }
        }
        .padding([.horizontal, .top], 14)
    }

    private func banner(_ message: String, isError: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.accentColor)
            Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { if isError { model.error = nil } else { model.notice = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background((isError ? Color.red : Color.accentColor).opacity(0.1), in: .rect(cornerRadius: 8))
        .padding([.horizontal, .top], 14)
        .transition(.opacity)
    }

    private var setupBanner: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Networking is not set up").font(.callout.weight(.semibold))
                Text(model.snap.missing == [Corral.sharedTLD] && Corral.herdIsRunning
                     ? "Herd serves .test. Quit Herd, then set up."
                     : "\(model.snap.missing.map { "." + $0 }.joined(separator: ", ")) names do not resolve yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set Up…") { model.run("Setting up") { try $0.install() } }
                .disabled(model.busy != nil)
        }
        .padding(10)
        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 8))
        .padding([.horizontal, .top], 14)
    }

    @ViewBuilder private var sites: some View {
        if model.snap.rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("No sites yet").font(.headline)
                Text("Add a folder to \(model.snap.parked.first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "a parked folder"), or park a folder that holds your projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Park Folder…", action: model.park).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            VStack(spacing: 0) {
                if model.snap.rows.count > 8 {
                    TextField("Filter sites", text: $model.filter)
                        .textFieldStyle(.roundedBorder)
                        .padding([.horizontal, .top], 10)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in SiteRow(row: row, model: model) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Global PHP", selection: Binding(
                    get: { model.snap.globalPHP ?? "" },
                    set: { v in model.run("Switching PHP") { c in c.config.php = v; try c.apply() } }
                )) {
                    ForEach(model.snap.versions, id: \.self) { Text("PHP \($0)").tag($0) }
                }
                .pickerStyle(.inline)
                let missing = Corral.phpChoices.filter { !model.snap.versions.contains($0) }
                if !missing.isEmpty {
                    Divider()
                    Menu("Install PHP") {
                        ForEach(missing, id: \.self) { v in
                            Button("PHP \(v)") { model.run("Installing PHP \(v)") { try $0.installPHP(v) } }
                        }
                    }
                }
            } label: {
                Label(model.snap.globalPHP.map { "PHP \($0)" } ?? "No PHP", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button(action: model.park) { Label("Park Folder", systemImage: "folder.badge.plus") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Park Folder")

            Menu {
                Toggle("Serve .test Instead of Herd", isOn: Binding(
                    get: { model.snap.ownsTest },
                    set: { on in
                        if on { model.run("Taking over .test") { try $0.takeover() } }
                        else { model.run("Giving .test back") { try $0.runAsAdmin($0.handbackScript()) } }
                    }
                ))
                Button("Restart Services") { model.run("Restarting") { c in c.stop(); try c.start() } }
                    .disabled(!model.running)
                Button("Open Config Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.snap.home)) }
                Divider()
                Button("Settings…") { NSApp.activate(); openSettings() }.keyboardShortcut(",")
                Divider()
                Button("Quit Corral") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

struct ServiceChip: View {
    let name: String
    let up: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(up ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(name).font(.caption).foregroundStyle(up ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(up ? "running" : "stopped")")
    }
}

// The Command Line Tools ship no SwiftUIMacros plugin, and @State is a macro in the current SDK.
// Plain property wrappers (@StateObject, @Published) keep the app buildable without Xcode.
final class Hover: ObservableObject { @Published var on = false }

struct SiteRow: View {
    let row: Snapshot.Row
    @ObservedObject var model: Model
    @StateObject private var hover = Hover()
    private var hovering: Bool { hover.on }

    var body: some View {
        Button { NSWorkspace.shared.open(row.url) } label: {
            HStack(spacing: 10) {
                Image(systemName: row.site.proxy == nil ? "folder" : "arrow.left.arrow.right")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.host).font(.body.weight(.medium)).lineLimit(1)
                        if row.secured {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("HTTPS")
                        }
                    }
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let php = row.php {
                    Text(php)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(row.isolated == nil ? .secondary : .primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(row.isolated == nil ? 0.4 : 1), in: .rect(cornerRadius: 4))
                        .help(row.isolated == nil ? "Global PHP version" : "PHP version pinned to this site")
                }
                actions.opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(hovering: hovering))
        .onHover { hover.on = $0 }
        .contextMenu { menuItems }
        .help("Open \(row.url.absoluteString)")
    }

    private var actions: some View {
        Menu { menuItems } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(row.host)")
    }

    @ViewBuilder private var menuItems: some View {
        let site = row.site
        Button("Open in Browser") { NSWorkspace.shared.open(row.url) }
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.url.absoluteString, forType: .string)
        }
        if site.proxy == nil {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.path)]) }
        }
        Divider()
        Toggle("Serve over HTTPS", isOn: Binding(
            get: { row.secured },
            set: { on in model.run(on ? "Securing \(row.host)" : "Removing HTTPS") { try $0.setSecure(site, on) } }
        ))
        if site.proxy == nil {
            Picker("PHP Version", selection: Binding(
                get: { row.isolated ?? "" },
                set: { v in model.run("Switching PHP") { c in c.config.isolated[site.name] = v.isEmpty ? nil : v; try c.apply() } }
            )) {
                Text("Global (\(model.snap.globalPHP ?? "none"))").tag("")
                ForEach(model.snap.versions, id: \.self) { Text("PHP \($0)").tag($0) }
            }
        }
    }
}

/// Row highlight on hover, slightly stronger on press. Feedback starts on press, not on release.
struct RowStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0),
                in: .rect(cornerRadius: 6)
            )
    }
}
