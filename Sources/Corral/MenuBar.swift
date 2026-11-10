import ServiceManagement
import SwiftUI

/// What the panel shows. Built on the work queue after each job, then published on the main actor.
struct Snapshot: Sendable {
    /// What a site is, from the files in its folder. The panel shows it as a small tile, so sites tell apart at a glance.
    enum Kind: Sendable {
        case laravel, wordpress, proxy, php

        init(_ site: Site) {
            let has = { FileManager.default.fileExists(atPath: site.path + "/" + $0) }
            if site.proxy != nil { self = .proxy }
            else if has("artisan") { self = .laravel }
            else if has("wp-config.php") || has("wp-content") || has("wp-load.php") || has("web/wp-config.php") { self = .wordpress }
            else { self = .php }
        }
    }

    struct Row: Identifiable, Sendable {
        let site: Site
        let host: String
        let url: URL
        let detail: String
        let php: String?
        let secured: Bool
        let isolated: String?
        let kind: Kind
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
    var builds: [String: String] = [:]     // PHP version -> full version, for example "8.4" -> "8.4.27"
    var iniPaths: [String: String] = [:]   // PHP version -> php.ini
    var ini: [String: [String: String]] = [:] // PHP version -> values of PHPSettings.keys
    var pools: [String: FpmPool] = [:]
    var loginItem = SMAppService.Status.notRegistered
    var tld = Config().tld
    var aliases: [String] = []
    var missing: [String] = []             // TLDs that do not resolve to Corral yet
    var herdFound = false
    var dumps = false
    var queries = false
    var wordpress = WordPressDefaults()
    var mail = false
    var xdebug = XdebugSettings()
    var xdebugBuilds: [String] = []        // PHP versions in use whose build has Xdebug
    var noXdebug: Set<String> = []         // installed PHP versions whose build is older than Xdebug
    var portless: [PortlessApp] = []
    var tools: [String: (version: String, updated: Bool)] = [:] // tool name -> the version bin/<tool> runs

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
                       php: version, secured: c.config.secured.contains(s.name), isolated: c.config.isolated[s.name], kind: Kind(s))
        }
        services = c.status().map { (name: $0.0, up: $0.1) }
        versions = Corral.sortVersions(php.keys)
        globalPHP = c.globalPHP(php)
        missing = c.resolverTLDs(sites).filter { !Corral.resolverIsCorral("/etc/resolver/" + $0) }
        installed = missing.isEmpty
        tld = c.config.tld
        herdFound = Corral.herdFound
        dumps = c.config.dumps
        queries = c.config.queries
        wordpress = c.config.wordpress
        mail = c.config.mail
        xdebug = c.config.xdebug
        xdebugBuilds = c.neededPHP(php).filter { php[$0].flatMap(c.xdebugPath) != nil }
        noXdebug = Set(php.filter { c.xdebugPath($0.value) == nil }.keys)
        portless = Corral.portlessApps()
        tools = Corral.tools.reduce(into: [:]) { $0[$1.name] = c.installedTool($1) }
        aliases = c.config.aliases
        ownsTest = c.ownsTest
        home = c.home
        parked = c.config.parked
        links = c.config.links.sorted { $0.key < $1.key }.map { (name: $0.key, path: $0.value) }
        proxies = c.config.proxies.sorted { $0.key < $1.key }.map { (name: $0.key, url: $0.value) }
        certs = sites.filter { c.config.secured.contains($0.name) }.map { (host: c.host($0), expires: c.certExpiry(c.certPath($0))) }
        builds = Dictionary(uniqueKeysWithValues: php.keys.compactMap { v in c.phpFullVersion(v).map { (v, $0) } })
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
    @Published var notice: String? { didSet { noticeIsBackground = false } } // inform() marks its own notices after this
    /// The job that just ended without an error, shown for a few seconds: completion feedback where the user acted.
    @Published private(set) var completed: String?
    /// Jobs in progress. The spinner stays until the last one ends, not the first.
    private var jobs = 0
    /// True when the notice came from the app itself (a restart, the editor), not from something the user did.
    private var noticeIsBackground = false

    /// A notice the app shows on its own. It never replaces the result of something the user did,
    /// such as the password of a new WordPress site.
    func inform(_ text: String) {
        guard notice == nil || noticeIsBackground else { return }
        notice = text
        noticeIsBackground = true
    }
    @Published var filter = ""
    @Published private(set) var latestPHP: [String: String] = [:] // PHP version -> newest full version in the build list
    @Published private(set) var update: Corral.Update? // a newer release than this app
    @Published private(set) var checkingUpdate = false
    @Published private(set) var updateStatus: String? // the result of a click on "Check for Updates", shown next to the button
    @Published private(set) var latestTools: [String: String] = [:] // tool name -> newest version

    private let corral: Corral
    private let queue = DispatchQueue(label: "dev.corral.work") // every Corral call from the app runs here

    /// Runs on the work queue, after Corral reads config.json again if the CLI changed it.
    private func onQueue(_ block: @escaping @Sendable () -> Void) {
        let corral = corral
        queue.async { corral.reloadIfChanged(); block() }
    }

    var running: Bool { snap.services.first?.up ?? false }

    private var watchdog: Timer?
    private var editorTimer: Timer?
    private var updateTimer: Timer?

    init(corral: Corral = Corral()) {
        self.corral = corral
        refresh()
        repair()
        addToPath()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repair() }
        }
        // An automatic update opens the new copy. Say so once, so the restart is not a mystery.
        if let version = Corral.appVersion, let last = UserDefaults.standard.string(forKey: "lastVersion"), last != version {
            inform("Corral updated to \(version).")
        }
        UserDefaults.standard.set(Corral.appVersion, forKey: "lastVersion")
        // Short, so "start listening" in the editor works for the next page load. lsof costs a few ms.
        editorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.detectEditor() }
        }
        checkForUpdate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate() }
        }
    }

    /// Starts the services that are down, if they ran before: after a login, or when a process stops.
    /// Like Herd's FpmRepair. The app is the only supervisor, so no LaunchAgent fights it.
    func repair() {
        guard busy == nil else { return }
        let corral = corral
        onQueue {
            // A `corral run` that got a SIGKILL could not remove its proxy. Put the old config back.
            let stale = corral.cleanStaleRuns()
            if !stale.isEmpty {
                var message: String?
                do { try corral.apply() } catch { message = error.localizedDescription }
                let snap = Snapshot(corral)
                Task { @MainActor in
                    self.snap = snap
                    if let message { self.error = message } else { self.inform("Removed the proxy of a stopped corral run: \(stale.joined(separator: ", "))).") }
                }
            }
            guard corral.wantsRunning else { return }
            let down = corral.status().filter { !$0.1 }.map(\.0)
            guard !down.isEmpty else { return }
            var message: String?
            do { try corral.start() } catch { message = error.localizedDescription }
            let snap = Snapshot(corral)
            Task { @MainActor in
                self.snap = snap
                if let message { if self.error != message { self.error = message } }
                else { self.inform("Restarted \(down.joined(separator: ", ")) at \(Date.now.formatted(date: .omitted, time: .shortened)).") }
            }
        }
    }

    /// While an editor listens on the Xdebug client port, every PHP request goes to the debug pool. Says so when it changes.
    private func detectEditor() {
        let corral = corral
        onQueue {
            guard corral.updateEditorFlag() else { return }
            let on = FileManager.default.fileExists(atPath: corral.editorFlag), port = corral.config.xdebug.clientPort
            Task { @MainActor in
                self.inform(on ? "Your editor listens on port \(port). Every PHP request now runs with Xdebug."
                    : "Your editor stopped listening. Requests run without Xdebug again.")
            }
        }
    }

    /// Keeps Corral's bin folder first in PATH, through the last line of ~/.zshrc. Says so only when the file changed.
    /// Only for the real home: a test or CORRAL_HOME home must not point the user's shell at its bin folder.
    private func addToPath() {
        let corral = corral
        guard corral.home == Corral.defaultHome else { return }
        onQueue {
            guard (try? corral.addToPath()) == true else { return }
            Task { @MainActor in self.inform("Corral put its bin folder first in PATH in ~/.zshrc. Open a new terminal to use Corral's php.") }
        }
    }

    /// Shows what a move from Herd changes (a dry run), then moves on confirmation.
    func moveFromHerd() {
        busy = "Reading Herd"
        error = nil
        let corral = corral
        onQueue {
            let plan = Result { try corral.importHerd(dryRun: true) }
            let loginItem = Corral.herdLoginItem
            Task { @MainActor in
                self.busy = nil
                switch plan {
                case .failure(let e): self.error = e.localizedDescription
                case .success(let plan): self.confirmMove(plan, loginItem: loginItem)
                }
            }
        }
    }

    private func confirmMove(_ plan: Corral.HerdImport, loginItem: Bool) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move from Herd to Corral?"
        alert.informativeText = plan.summary.joined(separator: "\n")
            + "\n\nCorral then quits Herd, serves .test and checks every site. Herd's own files do not change. To go back, run: corral migrate:herd --undo"
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        if loginItem {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remove Herd from login items"
            alert.suppressionButton?.state = .on
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removeLoginItem = loginItem && alert.suppressionButton?.state == .on
        run("Moving from Herd") { c in
            if removeLoginItem { try Corral.setHerdLoginItem(false) }
            _ = try c.importHerd()
            let problems = try c.finishHerdMove { done, total in
                Task { @MainActor in if self.busy != nil { self.busy = "Checking sites \(done)/\(total)" } }
            }
            let text = problems.isEmpty ? "Moved from Herd. Every site answers."
                : "Moved from Herd. These sites need attention: " + problems.map { "\($0.site) (\($0.problem))" }.joined(separator: ", ")
            Task { @MainActor in self.notice = text }
        }
    }

    /// Shows what goes, then uninstalls Herd on confirmation. Herd Pro data and the Valet CA each need their own yes.
    func uninstallHerd() {
        busy = "Reading Herd"
        error = nil
        onQueue {
            let plan = Corral.herdUninstallPlan()
            Task { @MainActor in
                self.busy = nil
                guard !plan.isEmpty else { self.notice = "Herd is not installed."; return }
                self.confirmUninstall(plan)
            }
        }
    }

    private func confirmUninstall(_ plan: HerdUninstall) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uninstall Herd?"
        alert.informativeText = plan.summary(removeCA: false).joined(separator: "\n")
            + "\n\nHerd.app and its folder stay in the Trash until you empty it. Corral asks for your password once."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if plan.valetCA {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also remove the Laravel Valet CA from the System keychain"
            alert.suppressionButton?.state = .off
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removeCA = plan.valetCA && alert.suppressionButton?.state == .on
        if let services = plan.services {
            let data = NSAlert()
            data.alertStyle = .critical
            data.messageText = "Herd Pro data goes to the Trash"
            data.informativeText = "\(services.path) holds Herd Pro databases and storage (\(ByteCountFormatter.string(fromByteCount: Int64(services.size), countStyle: .file))). Export what you need first."
            data.addButton(withTitle: "Cancel")
            data.addButton(withTitle: "Move to Trash")
            guard data.runModal() == .alertSecondButtonReturn else { return }
        }
        run("Uninstalling Herd") { c in
            let problems = try c.uninstallHerd(plan, removeCA: removeCA)
            let text = problems.isEmpty ? "Herd is uninstalled. Herd.app and its folder are in the Trash. Open a new terminal." : "Herd is uninstalled, with problems: " + problems.joined(separator: " ")
            Task { @MainActor in self.notice = text }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        run(nil) { _ in try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    func refresh() { run(nil) { _ in } }

    /// Reads the build list, so Settings can offer an update only when a newer build exists. Offline, it stays empty.
    func checkPHPUpdates() {
        let corral = corral
        onQueue {
            let latest = ((try? corral.phpManifest()) ?? [:]).compactMapValues { $0["version"] }
            Task { @MainActor in self.latestPHP = latest }
        }
    }

    /// Asks for the newest version of each tool, so Settings can offer an update only when there is one. Offline, it stays empty.
    func checkToolUpdates() {
        let corral = corral
        onQueue {
            var latest: [String: String] = [:]
            for tool in Corral.tools { latest[tool.name] = (try? corral.latestRelease(tool))?.version }
            let found = latest
            Task { @MainActor in self.latestTools = found.compactMapValues { $0 } }
        }
    }

    /// Looks for a newer release at launch and once a day. Installs it unless "Install updates automatically" is off.
    /// manual: a click on "Check for Updates". It reports next to the button and never installs by itself:
    /// the "Update to …" button that appears is the question. A background check stays quiet offline.
    func checkForUpdate(manual: Bool = false) {
        guard !checkingUpdate, busy == nil else { return }
        checkingUpdate = true
        if manual { updateStatus = nil }
        let corral = corral
        onQueue {
            var found: Corral.Update?, message: String?
            do { found = try corral.availableUpdate() } catch { message = error.localizedDescription }
            Task { @MainActor in
                self.checkingUpdate = false
                self.update = found
                if manual {
                    self.updateStatus = message.map { "Could not check: \($0)" }
                        ?? (found == nil ? "Corral is up to date. Checked at \(Date.now.formatted(date: .omitted, time: .shortened))." : nil)
                } else if found != nil && UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
                    self.installUpdate()
                }
            }
        }
    }

    /// Installs the release that checkForUpdate found, then opens the new copy and quits this one.
    /// The services keep running, and the new copy takes them over like after a login.
    func installUpdate() {
        guard let update, busy == nil else { return }
        busy = "Updating to Corral \(update.version)"; error = nil
        let corral = corral
        onQueue {
            var message: String?
            do { try corral.installUpdate(update) } catch { message = error.localizedDescription }
            Task { @MainActor in
                self.busy = nil
                if let message { self.error = message; return }
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
                try? relaunch.run()
                NSApp.terminate(nil)
            }
        }
    }

    /// Runs slow work (downloads, process starts) off the main thread, then refreshes the panel.
    func run(_ label: String?, _ work: @escaping @Sendable (Corral) throws -> Void) {
        if let label { jobs += 1; busy = label; error = nil; completed = nil }
        let corral = corral
        onQueue {
            var message: String?
            do { try work(corral) } catch { message = error.localizedDescription }
            let snap = Snapshot(corral)
            Task { @MainActor in
                self.snap = snap
                if let label {
                    self.jobs -= 1
                    if self.jobs == 0 { self.busy = nil }
                    if message == nil { self.confirm("\(label): done") }
                }
                if let message { self.error = message }
            }
        }
    }

    /// Completion feedback for 4 seconds, for example "Saving Xdebug settings: done" or "Copied https://shop.test".
    func confirm(_ text: String) {
        completed = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.completed == text { self?.completed = nil }
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

    /// Like `corral link` in a folder: serves one project as <folder>.<tld>.
    func link() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Corral serves the folder as <folder>.\(snap.tld)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = Corral.slug(url.lastPathComponent)
        run("Linking \(name)") { c in
            c.config.links[name] = url.path
            try c.apply()
        }
    }
}

extension Model {
    /// Services that must run but do not. Empty while Corral is stopped.
    var stoppedServices: [String] { running ? snap.services.filter { !$0.up }.map(\.name) : [] }

    /// One line for the quick menu header and the sidebar: all run, which one stopped, or stopped.
    var statusText: String {
        guard running else { return "Stopped" }
        let stopped = stoppedServices
        if stopped.isEmpty { return "Running · \(snap.services.count) services" }
        return stopped.count == 1 ? "\(stopped[0]) stopped" : "\(stopped.count) services stopped"
    }

    var statusColor: Color { !running ? Color.secondary.opacity(0.5) : stoppedServices.isEmpty ? .success : .warning }

    /// Each service with its state, for the tooltip of the status line.
    var serviceList: String { snap.services.map { "\($0.name): \($0.up ? "running" : "stopped")" }.joined(separator: "\n") }

    func restartServices() { run("Restarting") { c in c.stop(); try c.start() } }

    func showConfigFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: snap.home)) }
}

struct CorralApp: App {
    @StateObject private var model = Model()
    @StateObject private var insights = Insights()
    @StateObject private var mail = MailServer.shared

    init() {
        // AppKit controls (toolbar tabs, checkboxes, focus rings) use the system accent colour, which .tint cannot reach.
        // Orange (1) in Corral's own defaults is the closest system accent to Color.brand. Other apps keep theirs.
        UserDefaults.standard.set(1, forKey: "AppleAccentColor")
        Dock.update()
        Dock.followAppearance()
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Dock.update() }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { Dock.update(closing: closing) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(nsImage: Self.menuBarIcon(running: model.running)).accessibilityLabel(model.running ? "Corral, running" : "Corral, stopped")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }

        Window("Corral", id: "main") { MainView(model: model, insights: insights, mail: mail) }
            .commands { AppCommands(model: model) }
    }

    /// The app icon's mark without its tile, for the menu bar: the Hex C, its stacked outlines and the orange site.
    /// Ink on a light menu bar, cream on a dark one. Each outline erases what lies under it, because no tile colour
    /// hides the copies behind it as in AppIcon.svg. Stopped services dim it.
    static func menuBarIcon(running: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = dark ? CGColor(srgbRed: 0xEC / 255, green: 0xED / 255, blue: 0xE7 / 255, alpha: 1) : CGColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
            // With its outlines the mark spans 34...222 x 22...264 on the SVG's 256 grid. Scale it to 17 pt high and centre it.
            let scale: CGFloat = 17 / 242
            cg.translateBy(x: (18 - 188 * scale) / 2 - 34 * scale, y: (18 - 242 * scale) / 2 - 22 * scale)
            cg.scaleBy(x: scale, y: scale)
            let c = CGMutablePath(), site = CGMutablePath()
            c.addLines(between: [CGPoint(x: 207.67, y: 82), CGPoint(x: 128, y: 36), CGPoint(x: 48.33, y: 82),
                                 CGPoint(x: 48.33, y: 174), CGPoint(x: 128, y: 220), CGPoint(x: 207.67, y: 174)])
            site.addLines(between: [CGPoint(x: 128, y: 98), CGPoint(x: 154, y: 113), CGPoint(x: 154, y: 143),
                                    CGPoint(x: 128, y: 158), CGPoint(x: 102, y: 143), CGPoint(x: 102, y: 113)])
            site.closeSubpath()
            cg.setAlpha(running ? 1 : 0.45)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            for step in stride(from: 30, through: 0, by: -5) { // the farthest outline first, the solid C last
                let shape = c.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 10,
                                   transform: CGAffineTransform(translationX: 0, y: CGFloat(step)))
                cg.setBlendMode(.clear)
                cg.addPath(shape)
                cg.fillPath()
                cg.setBlendMode(.normal)
                cg.addPath(shape)
                if step == 0 {
                    cg.setFillColor(ink)
                    cg.fillPath()
                } else {
                    cg.setStrokeColor(ink)
                    cg.setLineWidth(2.6) // 1.3 in the SVG, doubled to stay visible at 18 pt
                    cg.strokePath()
                }
            }
            cg.addPath(site)
            cg.setFillColor(CGColor(srgbRed: 0xDF / 255, green: 0x5D / 255, blue: 0x09 / 255, alpha: 1))
            cg.fillPath()
            cg.endTransparencyLayer()
            return true
        }
    }

    /// The app icon tile at any size: AppIcon in light mode, AppIcon-Dark in dark mode, for the appearance it draws in.
    /// The .icns art keeps a 100/1024 margin for the shadow, so the drawing crops it and the tile fills the size.
    /// Stopped services dim it.
    static func appIcon(size: CGFloat, running: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let icon = Bundle.main.image(forResource: dark ? "AppIcon-Dark" : "AppIcon") ?? NSApplication.shared.applicationIconImage!
            icon.draw(in: rect.insetBy(dx: -size * 100 / 824, dy: -size * 100 / 824), from: .zero, operation: .sourceOver, fraction: running ? 1 : 0.45)
            return true
        }
    }
}

/// Corral is a menu bar app. It shows in the Dock and in ⌘-Tab while the main window or Settings is open,
/// or all the time with "Show Corral in the Dock". The menu bar panel cannot become main, so it does not count.
@MainActor enum Dock {
    static func update(closing: ObjectIdentifier? = nil) {
        let app = NSApplication.shared
        let open = app.windows.contains { ObjectIdentifier($0) != closing && $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = open || UserDefaults.standard.bool(forKey: "showInDock") ? .regular : .accessory
        guard app.activationPolicy() != policy else { return }
        app.setActivationPolicy(policy)
        if policy == .regular && open { app.activate() } // a new Dock icon starts behind the frontmost app
    }

    private static var appearance: NSKeyValueObservation?

    /// Uses AppIcon-Dark in dark mode. This changes the Dock and ⌘-Tab icon only:
    /// Finder shows the light AppIcon.icns, because a dark variant in the bundle needs Xcode's asset compiler.
    static func followAppearance() {
        appearance = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial]) { _, _ in
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                app.applicationIconImage = dark ? Bundle.main.image(forResource: "AppIcon-Dark") : nil
            }
        }
    }
}

extension Color {
    /// A color with one value for dark mode and one for light mode, each as 0xRRGGBB.
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Corral orange (#DF5D09), from the icon. Each mode gets a shade that keeps text readable (4.5:1 or more).
    /// Orange means "act". It is not a status color.
    static let brand = Color(dark: 0xF2762A, light: 0xC75208)
    /// A service is up. A teal, so it does not rely on red against green.
    static let success = Color(dark: 0x3DD6B5, light: 0x08705D)
    /// A service stopped. Yellow, so it does not look like the brand.
    static let warning = Color(dark: 0xF5C542, light: 0x8A6100)
    static let danger = Color(dark: 0xFF6B5E, light: 0xC0291D)
    // The glyph colors of the kind tile.
    static let kindLaravel = Color(dark: 0xFF8A7A, light: 0xB8321F)
    static let kindWordPress = Color(dark: 0x6FB1FF, light: 0x1F5FB8)
    static let kindProxy = Color(dark: 0x5FD0C5, light: 0x0B6F66)
    static let kindPHP = Color(dark: 0xB9B5AB, light: 0x5F5C55)
}

// MARK: - Panel

/// The quick menu under the menu bar icon: the status, three action tiles, and the commands.
/// The site list is in the main window.
struct Panel: View {
    @ObservedObject var model: Model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hideHerdMove") private var hideHerdMove = false
    @AppStorage("mainSection") private var section = "sites"
    @AppStorage("insightsTab") private var insightsTab = "dumps"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error { banner(error) }
            if let notice = model.notice { banner(notice, isError: false) }
            if model.snap.herdFound && !model.snap.ownsTest && !hideHerdMove { herdBanner }
            else if !model.snap.installed { setupBanner }
            tiles
            items
        }
        .frame(width: 280)
        .tint(.brand)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.error)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit(height: $0) }
        .onAppear { model.refresh() }
    }

    /// MenuBarExtra grows its window but never shrinks it. Without this, the panel floats in empty space
    /// after a banner closes. The panel is the key window that cannot become main.
    private func fit(height: CGFloat) {
        guard let window = NSApp.keyWindow, !window.canBecomeMain else { return }
        var frame = window.frame
        let newHeight = height + frame.height - window.contentLayoutRect.height
        guard abs(newHeight - frame.height) > 0.5 else { return }
        frame.origin.y += frame.height - newHeight // keep the top edge under the menu bar
        frame.size.height = newHeight
        window.setFrame(frame, display: true)
    }

    private var header: some View {
        // A stopped service is the one thing that stands out: its name, in the warning color.
        let warn = model.busy == nil && model.completed == nil && !model.stoppedServices.isEmpty
        return HStack(spacing: 8) {
            Image(nsImage: CorralApp.appIcon(size: 32))
            VStack(alignment: .leading, spacing: 2) {
                Text("Corral").font(.headline)
                HStack(spacing: 6) {
                    if model.busy != nil {
                        ProgressView().controlSize(.mini)
                    } else if model.completed == nil {
                        Circle().fill(model.statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(model.busy.map { "\($0)…" } ?? model.completed ?? model.statusText)
                        .font(.subheadline.weight(warn ? .semibold : .regular))
                        .foregroundStyle(warn ? AnyShapeStyle(Color.warning) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                .help(model.serviceList)
            }
            Spacer(minLength: 8)
            // Stop is rare, so it is quiet. Start is what a stopped Corral waits for, so it gets the accent.
            if model.running {
                Button(action: model.toggleServices) { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .help("Stop Services")
                    .accessibilityLabel("Stop Services")
                    .disabled(model.busy != nil)
            } else {
                Button("Start", action: model.toggleServices)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
            }
        }
        .padding([.horizontal, .top], 12)
    }

    private func banner(_ message: String, isError: Bool = true) -> some View {
        Banner(error: isError, title: message, dismiss: { if isError { model.error = nil } else { model.notice = nil } })
            .padding([.horizontal, .top], 12)
            .transition(.opacity)
    }

    private var setupBanner: some View {
        Banner(title: "Networking is not set up",
               detail: model.snap.missing == [Corral.sharedTLD] && Corral.herdIsRunning
                   ? "Herd serves .test. Quit Herd, then set up."
                   : "\(model.snap.missing.map { "." + $0 }.joined(separator: ", ")) names do not resolve yet.") {
            // A message that says "quit Herd" needs a button that does it.
            if model.snap.missing == [Corral.sharedTLD] && Corral.herdIsRunning {
                Button("Quit Herd") { model.run("Quitting Herd") { _ in try Corral.quitHerd() } }.disabled(model.busy != nil)
            }
            Button("Set Up…") { model.run("Setting up") { try $0.install() } }.disabled(model.busy != nil)
        }
        .padding([.horizontal, .top], 12)
    }

    // The menu keeps "Move from Herd…" after this banner is dismissed.
    private var herdBanner: some View {
        Banner(title: "Laravel Herd found", detail: "Move its sites, PHP versions and settings.", dismiss: { hideHerdMove = true }) {
            Button("Move…", action: model.moveFromHerd).disabled(model.busy != nil)
        }
        .padding([.horizontal, .top], 12)
    }

    /// The three commands that start at once and that the user starts most from the menu bar.
    private var tiles: some View {
        HStack(spacing: 6) {
            tile("Restart", "arrow.clockwise", action: model.restartServices)
                .disabled(!model.running || model.busy != nil)
                .help("Restart Services")
            tile("Park Folder", "folder.badge.plus", action: model.park)
            tile("Config", "folder", action: model.showConfigFolder)
                .help("Show Config Folder in Finder")
        }
        .padding([.horizontal, .top], 12)
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.body).foregroundStyle(.secondary).frame(height: 16)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(TileStyle())
    }

    private func openMain() { NSApp.activate(); openWindow(id: "main") }

    private var items: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Open Corral", symbol: "macwindow", shortcut: "⌘O", action: openMain).keyboardShortcut("o")
            MenuRow(title: "Insights", symbol: "chart.bar", shortcut: "⌘I") { section = insightsTab; openMain() }.keyboardShortcut("i")
            Menu { GlobalPHPMenu(model: model) } label: {
                Label(model.snap.globalPHP.map { "Global PHP \($0)" } ?? "No PHP", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(.primary) // orange labels fade on the translucent panel over a light window
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { NSApp.activate(); openSettings() }.keyboardShortcut(",")
            // Only with Herd on the Mac, and off when .test is the main TLD: the same rules as in Settings.
            if model.snap.herdFound {
                Divider().padding(.horizontal, 8).padding(.vertical, 4)
                MenuRow(title: "Serve .test Instead of Herd", symbol: model.snap.ownsTest ? "checkmark.circle.fill" : "circle") {
                    if model.snap.ownsTest { model.run("Giving .test back") { try $0.runAsAdmin($0.handbackScript()) } }
                    else { model.run("Taking over .test") { try $0.takeover() } }
                }
                .disabled(model.snap.tld == Corral.sharedTLD)
                .accessibilityValue(model.snap.ownsTest ? "On" : "Off")
                MenuRow(title: "Move from Herd…", symbol: "arrow.left.arrow.right", action: model.moveFromHerd).disabled(model.busy != nil)
                if model.snap.ownsTest && FileManager.default.fileExists(atPath: "/Applications/Herd.app") {
                    MenuRow(title: "Uninstall Herd…", symbol: "trash", action: model.uninstallHerd).disabled(model.busy != nil)
                }
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            MenuRow(title: "Quit Corral", symbol: "rectangle.portrait.and.arrow.right", shortcut: "⌘Q") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(6)
    }
}

/// The global PHP version as menu content, with the versions that Corral can install. The quick menu and the app menu share it.
struct GlobalPHPMenu: View {
    @ObservedObject var model: Model

    var body: some View {
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
    }
}

/// One command in the quick menu: a symbol, a title, and the shortcut on the right.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut = ""
    let action: () -> Void
    @StateObject private var hover = Hover()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(shortcut).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(hovering: hover.on && enabled))
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover.on = $0 }
    }
}

/// An action tile of the quick menu: a quiet fill, stronger on press.
struct TileStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: .rect(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Pieces

/// One look for every inline message in the app: errors, notices and prompts.
/// Radius rule: containers 8 pt, rows 6 pt, chips and badges capsule.
struct Banner<Actions: View>: View {
    var error = false
    let title: String
    var detail: String?
    var dismiss: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: detail == nil ? .firstTextBaseline : .center, spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(error ? Color.danger : Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(detail == nil ? .callout : .callout.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            actions
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background((error ? Color.danger : Color.brand).opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

extension Banner where Actions == EmptyView {
    init(error: Bool = false, title: String, detail: String? = nil, dismiss: (() -> Void)? = nil) {
        self.init(error: error, title: title, detail: detail, dismiss: dismiss) { EmptyView() }
    }
}

// The Command Line Tools ship no SwiftUIMacros plugin, and @State is a macro in the current SDK.
// Plain property wrappers (@StateObject, @Published) keep the app buildable without Xcode.
final class Hover: ObservableObject { @Published var on = false }

/// A small rounded tile for the kind of site: a letter for a framework, a symbol otherwise. The ground is
/// neutral and only the glyph has a color, so a long list stays calm and the names stay the strongest element.
struct KindTile: View {
    let kind: Snapshot.Kind

    var body: some View {
        let (color, mark): (Color, String?) = switch kind {
        case .laravel: (.kindLaravel, "L")
        case .wordpress: (.kindWordPress, "W")
        case .proxy: (.kindProxy, nil)
        case .php: (.kindPHP, nil)
        }
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 20, height: 20)
            .overlay {
                if let mark {
                    Text(mark).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(color)
                } else {
                    Image(systemName: kind == .proxy ? "arrow.left.arrow.right" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                }
            }
            .accessibilityLabel(kind.name)
    }
}

extension Snapshot.Kind {
    var name: String {
        switch self { case .laravel: "Laravel"; case .wordpress: "WordPress"; case .proxy: "Proxy"; case .php: "PHP" }
    }
}

struct SiteRow: View {
    let row: Snapshot.Row
    @ObservedObject var model: Model
    @StateObject private var hover = Hover()
    private var hovering: Bool { hover.on }

    var body: some View {
        // One line for each site: kind, name, lock, then the PHP version and the folder in columns.
        // The top level domain is quiet, so the eye reads the name first. A pinned PHP version shows as a badge.
        let dot = row.host.lastIndex(of: ".") ?? row.host.endIndex
        Button { NSWorkspace.shared.open(row.url) } label: {
            HStack(spacing: 8) {
                KindTile(kind: row.kind)
                Text("\(Text(row.host[..<dot]).fontWeight(.medium))\(Text(row.host[dot...]).foregroundStyle(.secondary))")
                    .lineLimit(1).truncationMode(.middle)
                if row.secured {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("HTTPS")
                }
                Spacer(minLength: 8)
                Group {
                    if let pinned = row.isolated {
                        Text(pinned)
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: .rect(cornerRadius: 4))
                            .help("PHP version pinned to this site")
                    } else {
                        Text(row.php ?? "").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .help("Global PHP version")
                    }
                }
                .frame(width: 44, alignment: .leading)
                Text(row.detail).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                    .layoutPriority(-1)
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
            model.confirm("Copied \(row.url.absoluteString)") // a copy shows nothing else, so say it worked
        }
        let laravel = FileManager.default.fileExists(atPath: site.path + "/artisan")
        if site.proxy == nil && (laravel || Corral.wordPressContent(site.path) != nil) {
            Button("Send Mail to Corral") {
                model.run(laravel ? "Changing .env" : "Adding the mail plugin") { c in
                    let file = try c.useCorralMail(site)
                    let hint = laravel ? "Run php artisan config:clear if the config is cached." : "Delete \((file as NSString).abbreviatingWithTildeInPath) to stop."
                    if !c.config.mail { c.config.mail = true; try c.save() }
                    Task { @MainActor in
                        MailServer.shared.start() // no dead end: the mail has somewhere to go right away
                        model.notice = "\(site.name) sends mail to Corral. See it in Insights > Mail. \(hint)"
                    }
                }
            }
        }
        if site.proxy == nil && Corral.needsWordPressSetup(site.path) {
            Button("Set Up WordPress") { // no "…": it starts at once, with no dialog
                model.run("Setting up \(site.name)") { c in
                    try c.setUpWordPress(site)
                    let wp = c.config.wordpress
                    Task { @MainActor in model.notice = "WordPress is ready at \(row.host)/wp-admin (user \(wp.adminUser), password \(wp.adminPassword))." }
                }
            }
        }
        if site.proxy == nil && FileManager.default.fileExists(atPath: site.path + "/wp-config.php") {
            Button("Import Database…") { importDump(site) }
        }
        if site.proxy == nil && Corral.needsLaravelSetup(site.path) {
            Button("Set Up Laravel") {
                model.run("Setting up \(site.name)") { c in
                    try c.setUpLaravel(site)
                    Task { @MainActor in model.notice = "\(row.host) is set up: dependencies, .env, key, database, migrations." }
                }
            }
        }
        if site.proxy == nil {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.path)]) }
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

extension SiteRow {
    /// Asks for a SQL dump, then imports it. The old address becomes this site's address.
    func importDump(_ site: Site) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql"), .init(filenameExtension: "gz")].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "The dump replaces the tables in the database of \(site.name). Corral then changes the old address to \(row.host)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.run("Importing into \(site.name)") { c in
            let summary = try c.importWordPressDump(site, dump: url.path)
            Task { @MainActor in model.notice = summary }
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
