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
    var herdFound = false
    var dumps = false
    var mail = false

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
        herdFound = Corral.herdFound
        dumps = c.config.dumps
        mail = c.config.mail
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

    /// Shows what a move from Herd changes (a dry run), then moves on confirmation.
    func moveFromHerd() {
        busy = "Reading Herd"
        error = nil
        let corral = corral
        queue.async {
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
            let problems = try c.finishHerdMove()
            let text = problems.isEmpty ? "Moved from Herd. Every site answers."
                : "Moved from Herd. These sites need attention: " + problems.map { "\($0.site) (\($0.problem))" }.joined(separator: ", ")
            Task { @MainActor in self.notice = text }
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
    @StateObject private var insights = Insights()
    @StateObject private var mail = MailServer()

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
            Image(nsImage: Self.logo(size: 18, running: model.running)).accessibilityLabel("Corral")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }

        Window("Insights", id: "insights") { InsightsView(model: model, insights: insights, mail: mail) }
    }

    /// The Hex C from Resources/AppIcon.svg, drawn at any size. The site hexagon shows only while the services run.
    /// A template image is black for macOS to colour. Otherwise the C uses the label colour and the site is Corral orange.
    static func logo(size: CGFloat, running: Bool = true, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // The mark spans 34...222 x 22...234 on the SVG's 256 grid, stroke included. Scale it to 8/9 of the size and centre it.
            let scale = size * 8 / 9 / 212, transform = NSAffineTransform()
            transform.translateX(by: (size - 188 * scale) / 2 - 34 * scale, yBy: (size - 212 * scale) / 2 - 22 * scale)
            transform.scale(by: scale)
            let c = NSBezierPath(), site = NSBezierPath()
            c.move(to: NSPoint(x: 207.67, y: 82))
            for (x, y): (CGFloat, CGFloat) in [(128, 36), (48.33, 82), (48.33, 174), (128, 220), (207.67, 174)] { c.line(to: NSPoint(x: x, y: y)) }
            site.move(to: NSPoint(x: 128, y: 98))
            for (x, y): (CGFloat, CGFloat) in [(154, 113), (154, 143), (128, 158), (102, 143), (102, 113)] { site.line(to: NSPoint(x: x, y: y)) }
            site.close()
            c.transform(using: transform as AffineTransform)
            site.transform(using: transform as AffineTransform)
            c.lineWidth = 28 * scale
            c.lineJoinStyle = .round
            c.lineCapStyle = .round
            (template ? NSColor.black : NSColor.labelColor).set()
            c.stroke()
            (template ? NSColor.black : NSColor(srgbRed: 0xDF / 255, green: 0x5D / 255, blue: 0x09 / 255, alpha: 1)).set()
            if running { site.fill() }
            return true
        }
        image.isTemplate = template
        return image
    }
}

/// Corral is a menu bar app. It shows in the Dock and in ⌘-Tab while Settings or Insights is open,
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
    /// Corral orange (#DF5D09), from the icon. Each mode gets a shade that keeps text readable (4.5:1 or more).
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF2 / 255, green: 0x76 / 255, blue: 0x2A / 255, alpha: 1)
            : NSColor(srgbRed: 0xC7 / 255, green: 0x52 / 255, blue: 0x08 / 255, alpha: 1)
    })
}

// MARK: - Panel

struct Panel: View {
    @ObservedObject var model: Model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hideHerdMove") private var hideHerdMove = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [Snapshot.Row] {
        model.filter.isEmpty ? model.snap.rows : model.snap.rows.filter { $0.host.localizedCaseInsensitiveContains(model.filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error { banner(error) }
            if let notice = model.notice { banner(notice, isError: false) }
            if model.snap.herdFound && !model.snap.ownsTest && !hideHerdMove { herdBanner }
            else if !model.snap.installed { setupBanner }
            Divider().padding(.top, 10)
            sites
            Divider()
            footer
        }
        .frame(width: 360)
        .tint(.brand)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.snap.rows.map(\.id))
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.error)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit(height: $0) }
        .onAppear { model.refresh() }
    }

    /// MenuBarExtra grows its window but never shrinks it. Without this, the panel floats in empty space
    /// after a banner closes or the filter hides sites. The panel is the key window that cannot become main.
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: CorralApp.logo(size: 28))
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
                    .tint(model.running ? .secondary : .brand)
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
        Banner(error: isError, title: message, dismiss: { if isError { model.error = nil } else { model.notice = nil } })
            .padding([.horizontal, .top], 14)
            .transition(.opacity)
    }

    private var setupBanner: some View {
        Banner(title: "Networking is not set up",
               detail: model.snap.missing == [Corral.sharedTLD] && Corral.herdIsRunning
                   ? "Herd serves .test. Quit Herd, then set up."
                   : "\(model.snap.missing.map { "." + $0 }.joined(separator: ", ")) names do not resolve yet.") {
            Button("Set Up…") { model.run("Setting up") { try $0.install() } }.disabled(model.busy != nil)
        }
        .padding([.horizontal, .top], 14)
    }

    // The More menu keeps "Move from Herd…" after this banner is dismissed.
    private var herdBanner: some View {
        Banner(title: "Laravel Herd found", detail: "Move its sites, PHP versions and settings.", dismiss: { hideHerdMove = true }) {
            Button("Move…", action: model.moveFromHerd).disabled(model.busy != nil)
        }
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
                if model.snap.rows.count > 8 { filterField }
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

    /// A quiet search field in the panel's 8 pt container style, not the boxed AppKit text field.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter sites", text: $model.filter).textFieldStyle(.plain)
            if !model.filter.isEmpty {
                Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .padding([.horizontal, .top], 10)
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
                if model.snap.herdFound {
                    Button("Move from Herd…", action: model.moveFromHerd).disabled(model.busy != nil)
                }
                Button("Restart Services") { model.run("Restarting") { c in c.stop(); try c.start() } }
                    .disabled(!model.running)
                Button("Open Config Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.snap.home)) }
                Divider()
                Button("Insights…") { NSApp.activate(); openWindow(id: "insights") }.keyboardShortcut("i")
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
        .tint(.primary) // orange labels fade on the translucent panel over a light window
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
                .foregroundStyle(error ? Color.red : Color.brand)
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
        .background((error ? Color.red : Color.brand).opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

extension Banner where Actions == EmptyView {
    init(error: Bool = false, title: String, detail: String? = nil, dismiss: (() -> Void)? = nil) {
        self.init(error: error, title: title, detail: detail, dismiss: dismiss) { EmptyView() }
    }
}

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
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(row.isolated == nil ? 0.4 : 1), in: .capsule)
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
        if site.proxy == nil && FileManager.default.fileExists(atPath: site.path + "/artisan") {
            Button("Send Mail to Corral") {
                model.run("Changing .env") { c in
                    try c.useCorralMail(site)
                    Task { @MainActor in model.notice = "\(site.name) sends mail to Corral. Turn on mail in Insights. Run php artisan config:clear if the config is cached." }
                }
            }
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
