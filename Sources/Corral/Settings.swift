import ServiceManagement
import SwiftUI

/// The settings window (⌘,). Every change runs on Model's work queue, like the panel.
struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
                PHPTab(model: model).tabItem { Label("PHP", systemImage: "chevron.left.forwardslash.chevron.right") }
                ToolsTab(model: model).tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                SitesTab(model: model).tabItem { Label("Sites", systemImage: "folder") }
                CertificatesTab(model: model).tabItem { Label("Certificates", systemImage: "lock") }
                AboutTab(model: model).tabItem { Label("About", systemImage: "info.circle") }
            }
            StatusLine(model: model)
        }
        .frame(width: 580, height: 460)
        .tint(.brand)
        .onAppear { model.refresh() }
    }
}

/// A section footer. The Settings window aligns multi-line footers to the trailing edge, which looks broken under
/// leading labels, so every footer sets its alignment itself.
struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status of the window's work, under the tabs: the job in progress, the last error, the job that just
/// ended, or a notice. Each of the four kinds of feedback shows where the user acted, not only in the panel.
struct StatusLine: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.busy != nil || model.error != nil || model.completed != nil || model.notice != nil {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if let busy = model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(busy)…").foregroundStyle(.secondary) }
                    } else if let error = model.error {
                        line("exclamationmark.triangle.fill", .red, error) { model.error = nil }
                    } else if let completed = model.completed {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("\(completed): done").foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if let notice = model.notice {
                        line("info.circle.fill", Color.brand, notice) { model.notice = nil }
                    }
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(.bar)
        }
    }

    private func line(_ icon: String, _ color: Color, _ text: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: Model
    @StateObject private var domains = DomainDraft()
    @AppStorage("showInDock") private var showInDock = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Corral at login", isOn: Binding(
                    get: { model.snap.loginItem == .enabled || model.snap.loginItem == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                if model.snap.loginItem == .requiresApproval {
                    LabeledContent("Allow Corral in Login Items") {
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: {
                Footer("Corral starts the services again if they ran before, and restarts a service that stops.")
            }
            Section {
                Toggle("Show Corral in the Dock", isOn: $showInDock).onChange(of: showInDock) { Dock.update() }
            } footer: {
                Footer("Corral always shows in the Dock and in ⌘-Tab while a Corral window is open. Turn this on to keep it there.")
            }
            Section {
                TextField("Main TLD", text: $domains.tld)
                TextField("Extra TLDs", text: $domains.aliases, prompt: Text("internal"))
                LabeledContent("") {
                    Button("Apply", action: applyDomains)
                        .disabled(model.busy != nil || (domains.tld == model.snap.tld && domains.aliases == model.snap.aliases.joined(separator: ", ")))
                }
            } header: {
                Text("Domains")
            } footer: {
                Footer("Each site answers <site>.<TLD> for every TLD. A site can add more names with \"domains\" in .corral.json. Corral asks for your password to update /etc/resolver.")
            }
            if model.snap.herdFound { // the same rules as the switch in the panel's menu
                Section {
                    Toggle("Serve .test instead of Herd", isOn: Binding(
                        get: { model.snap.ownsTest },
                        set: { on in
                            if on { model.run("Taking over .test") { try $0.takeover() } }
                            else { model.run("Giving .test back") { try $0.runAsAdmin($0.handbackScript()) } }
                        }
                    ))
                } footer: {
                    Footer("Quit Herd first. Herd takes .test back while it runs.")
                }
                .disabled(model.snap.tld == Corral.sharedTLD)
            }
            Section {
                LabeledContent("Services") {
                    Button("Restart") { model.run("Restarting") { c in c.stop(); try c.start() } }.disabled(!model.running)
                }
                LabeledContent("Config folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.snap.home)) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { domains.tld = model.snap.tld; domains.aliases = model.snap.aliases.joined(separator: ", ") }
    }

    private func applyDomains() {
        let label = /^[a-z0-9-]+$/
        let tld = domains.tld.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases = domains.aliases.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != tld }
        guard ([tld] + aliases).allSatisfy({ $0.wholeMatch(of: label) != nil }) else {
            model.error = "A TLD can have only letters, digits and hyphens, for example test or internal."
            return
        }
        model.run("Changing domains") { c in
            c.config.tld = tld
            c.config.aliases = aliases
            try c.apply()
            if !c.isInstalled { try c.install() }
        }
    }
}

/// Text field values for the domain settings.
final class DomainDraft: ObservableObject {
    @Published var tld = ""
    @Published var aliases = ""
}

struct PHPTab: View {
    @ObservedObject var model: Model
    @StateObject private var settings = PHPSettings()
    @StateObject private var xdebug = XdebugDraft()

    /// Removing a version breaks the sites that use it, and only a new download brings it back, so ask first.
    /// The alert names those sites, so the answer is an informed one.
    private func confirmRemove(_ version: String) -> Bool {
        let users = model.snap.rows.filter { $0.php == version }.map(\.host)
        let alert = NSAlert()
        alert.alertStyle = users.isEmpty ? .informational : .warning
        alert.messageText = "Remove PHP \(version)?"
        // Sites fall back to the global version. Without it, the global version becomes the newest one left.
        let fallback = model.snap.globalPHP == version ? model.snap.versions.last { $0 != version } : model.snap.globalPHP
        var lines: [String] = []
        if model.snap.globalPHP == version, let fallback { lines.append("It is the global PHP version. PHP \(fallback) becomes the global version.") }
        if users.isEmpty {
            lines.append("No site uses it.")
        } else {
            let shown = users.prefix(8).joined(separator: ", ") + (users.count > 8 ? ", and \(users.count - 8) more" : "")
            let effect = fallback.map { "switch to PHP \($0)" } ?? "stop working, because no other PHP version is installed"
            lines.append("\(users.count == 1 ? "This site uses it and will" : "These \(users.count) sites use it and will") \(effect): \(shown).")
        }
        lines.append("Its php.ini goes too. You can install the version again later.")
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var body: some View {
        Form {
            Section("Installed") {
                if model.snap.versions.isEmpty { Text("No PHP version is installed.").foregroundStyle(.secondary) }
                ForEach(model.snap.versions.reversed(), id: \.self) { v in
                    let full = model.snap.builds[v]
                    let latest = model.latestPHP[v]
                    let newer = latest.map { $0.compare(full ?? v, options: .numeric) == .orderedDescending } ?? false
                    LabeledContent {
                        HStack {
                            if let ini = model.snap.iniPaths[v] {
                                Button("php.ini") { NSWorkspace.shared.open(URL(fileURLWithPath: ini)) }.help(ini)
                            }
                            if newer, let latest {
                                Button("Update to \(latest)") { model.run("Updating PHP \(v) to \(latest)") { try $0.installPHP(v) } }
                            } else if latest != nil, model.snap.noXdebug.contains(v) {
                                // The same version, built before Xdebug was in the builds. Installing again adds xdebug.so.
                                Button("Get Xdebug") { model.run("Installing PHP \(v) again with Xdebug") { try $0.installPHP(v) } }
                            }
                            Button("Remove…") { if confirmRemove(v) { model.run("Removing PHP \(v)") { try $0.uninstallPHP(v) } } }
                        }
                        .disabled(model.busy != nil)
                    } label: {
                        Text("PHP \(full ?? v)")
                        Text(newer ? "Update available" : latest == nil ? "Corral build" : "Up to date")
                    }
                }
                Picker("Settings for", selection: Binding(get: { settings.version ?? "" }, set: { settings.switchTo($0, model.snap) })) {
                    ForEach(model.snap.versions.reversed(), id: \.self) { Text("PHP \($0)").tag($0) }
                }
            }
            if let version = settings.version, model.snap.versions.contains(version) {
                PHPSettingsSections(model: model, settings: settings, version: version)
            }
            XdebugSection(model: model, draft: xdebug)
            Section {
                Picker("Global version", selection: Binding(
                    get: { model.snap.globalPHP ?? "" },
                    set: { v in model.run("Switching PHP") { c in c.config.php = v; try c.apply() } }
                )) {
                    ForEach(model.snap.versions, id: \.self) { Text("PHP \($0)").tag($0) }
                }
                let missing = Corral.phpChoices.filter { !model.snap.versions.contains($0) }
                if !missing.isEmpty {
                    LabeledContent("Install") {
                        HStack {
                            ForEach(missing, id: \.self) { v in
                                Button(model.latestPHP[v] ?? v) { model.run("Installing PHP \(v)") { try $0.installPHP(v) } }
                            }
                        }
                        .disabled(model.busy != nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if settings.version == nil, let v = model.snap.globalPHP { settings.load(v, model.snap) }
            model.checkPHPUpdates()
        }
    }
}

/// Field values for one PHP version, loaded from its php.ini and FPM pool.
@MainActor
final class PHPSettings: ObservableObject {
    /// php.ini keys with a field. upload_max_filesize also sets post_max_size.
    nonisolated static let keys = ["memory_limit", "upload_max_filesize", "max_execution_time", "max_input_vars", "display_errors",
                                   "error_reporting", "date.timezone", "opcache.enable", "output_buffering"]

    @Published var version: String?
    @Published var ini: [String: String] = [:]
    @Published var pool = FpmPool()

    func load(_ version: String, _ snap: Snapshot) {
        self.version = version
        ini = snap.ini[version] ?? [:]
        pool = snap.pools[version] ?? FpmPool()
    }

    /// Edits that Apply has not saved yet.
    func changed(_ snap: Snapshot) -> Bool {
        guard let version else { return false }
        return ini != (snap.ini[version] ?? [:]) || pool != (snap.pools[version] ?? FpmPool())
    }

    /// Another version in "Settings for" would drop the edits, so ask first when there are any.
    func switchTo(_ version: String, _ snap: Snapshot) {
        guard version != self.version else { return }
        if changed(snap), let current = self.version {
            let alert = NSAlert()
            alert.messageText = "Discard the changes to PHP \(current)?"
            alert.informativeText = "You changed settings of PHP \(current) and did not apply them."
            alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        load(version, snap)
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.ini[key] ?? "" }, set: { self.ini[key] = $0 })
    }

    /// php.ini accepts On, 1, true and yes.
    func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { ["on", "1", "true", "yes", "stdout", "stderr"].contains(self.ini[key]?.lowercased() ?? "") },
                set: { self.ini[key] = $0 ? "On" : "Off" })
    }

    func number(_ path: WritableKeyPath<FpmPool, Int>) -> Binding<String> {
        Binding(get: { String(self.pool[keyPath: path]) }, set: { self.pool[keyPath: path] = Int($0) ?? self.pool[keyPath: path] })
    }
}

struct PHPSettingsSections: View {
    @ObservedObject var model: Model
    @ObservedObject var settings: PHPSettings
    let version: String

    var body: some View {
        Section {
            TextField("Memory limit", text: settings.binding("memory_limit"), prompt: Text("1024M, or -1 for no limit"))
            TextField("Maximum upload size", text: settings.binding("upload_max_filesize"), prompt: Text("512M"))
            TextField("Maximum execution time (seconds)", text: settings.binding("max_execution_time"), prompt: Text("600"))
            TextField("Maximum input variables", text: settings.binding("max_input_vars"), prompt: Text("1000"))
            Toggle("Display errors", isOn: settings.flag("display_errors"))
            TextField("Error reporting", text: settings.binding("error_reporting"), prompt: Text("E_ALL"))
            TextField("Time zone", text: settings.binding("date.timezone"), prompt: Text("UTC"))
            Toggle("OPcache", isOn: settings.flag("opcache.enable"))
            TextField("Output buffering (bytes)", text: settings.binding("output_buffering"), prompt: Text("4096"))
        } header: {
            Text("PHP \(version) settings")
        }
        Section {
            Picker("Process manager", selection: $settings.pool.pm) {
                Text("Dynamic").tag("dynamic")
                Text("On demand").tag("ondemand")
                Text("Static").tag("static")
            }
            TextField("Maximum processes", text: settings.number(\.maxChildren))
            TextField("Request timeout (seconds, 0 = none)", text: settings.number(\.requestTerminateTimeout))
            TextField("Slow log after (seconds, 0 = off)", text: settings.number(\.slowlogTimeout))
        } header: {
            Text("PHP-FPM")
        }
        // One Apply for both sections above, in its own row, so it is clear that it saves both.
        Section {
            LabeledContent(settings.changed(model.snap) ? "PHP \(version) has changes that are not applied" : "No changes") {
                HStack {
                    Button("Revert") { settings.load(version, model.snap) }
                    Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                }
                .disabled(model.busy != nil || !settings.changed(model.snap))
            }
        } footer: {
            Footer("Apply saves the PHP \(version) settings and the PHP-FPM settings. Corral checks the values with PHP before it saves them, then reloads PHP \(version). A site can set its own values with \"php\" in .corral.json.")
        }
    }

    private func apply() {
        var values = settings.ini.filter { !$0.value.isEmpty }
        if let upload = values["upload_max_filesize"] { values["post_max_size"] = upload } // a smaller post_max_size would cap uploads
        if let tz = values["date.timezone"], TimeZone(identifier: tz) == nil {
            model.error = "\(tz) is not a time zone. Use a name such as Europe/Stockholm."
            return
        }
        let (version, pool, ini) = (version, settings.pool, values)
        model.run("Saving PHP \(version) settings") { try $0.savePHPSettings(version, ini: ini, pool: pool) }
    }
}

/// The debug pool settings. Values stay text until Apply, so a half-typed port does not change anything.
@MainActor
final class XdebugDraft: ObservableObject {
    @Published var enabled = false
    @Published var mode = ""
    @Published var host = ""
    @Published var port = ""
    @Published var start = "yes"
    @Published var profile = false
    @Published var detect = true
    private var loaded = false

    func load(_ x: XdebugSettings) {
        (enabled, mode, host, port, start, profile, detect) = (x.enabled, x.mode, x.clientHost, String(x.clientPort), x.startWithRequest, x.profile, x.detectEditor)
        loaded = true
    }

    func settings() -> XdebugSettings? {
        guard let port = Int(port) else { return nil }
        var x = XdebugSettings()
        (x.enabled, x.mode, x.clientHost, x.clientPort, x.startWithRequest, x.profile, x.detectEditor) = (enabled, mode, host, port, start, profile, detect)
        return x
    }

    func loadOnce(_ x: XdebugSettings) { if !loaded { load(x) } }
}

struct XdebugSection: View {
    @ObservedObject var model: Model
    @ObservedObject var draft: XdebugDraft

    var body: some View {
        Section {
            Toggle("Debug pool (Xdebug)", isOn: $draft.enabled)
            TextField("Mode", text: $draft.mode, prompt: Text("debug,develop"))
            TextField("Client host", text: $draft.host, prompt: Text("127.0.0.1"))
            TextField("Client port", text: $draft.port, prompt: Text("9003"))
            Picker("Start a session", selection: $draft.start) {
                Text("For every request in the pool").tag("yes")
                Text("Only with XDEBUG_TRIGGER").tag("trigger")
            }
            .disabled(draft.profile)
            Toggle("Profiler (XDEBUG_PROFILE)", isOn: $draft.profile).disabled(!draft.enabled)
            Toggle("Use the pool while the editor listens", isOn: $draft.detect).disabled(!draft.enabled)
                .help("While a program listens on the client port on this Mac, every PHP request runs with Xdebug, without a cookie.")
            LabeledContent("") {
                HStack {
                    Button("Revert") { draft.load(model.snap.xdebug) }
                    Button("Apply", action: apply)
                }
                .disabled(model.busy != nil || draft.settings() == model.snap.xdebug)
            }
        } header: {
            Text("Xdebug")
        } footer: {
            Footer(footer)
        }
        .onAppear { draft.loadOnce(model.snap.xdebug) }
    }

    private var footer: String {
        let using = model.snap.xdebugBuilds.isEmpty
            ? "No PHP build in use has Xdebug. Click \"Get Xdebug\" or \"Update to …\" next to a version above."
            : "Debug pool for PHP \(model.snap.xdebugBuilds.joined(separator: ", "))."
        return "A request with an XDEBUG_SESSION or XDEBUG_TRIGGER cookie or query argument runs in a second PHP-FPM pool that has Xdebug. Other requests run without it and stay fast. With the profiler on, XDEBUG_PROFILE also uses the pool and writes a cachegrind file (see Insights > Profiles), and each trigger starts only its own mode. \(using)"
    }

    private func apply() {
        guard let x = draft.settings() else {
            model.error = "The client port must be a number."
            return
        }
        model.run("Saving Xdebug settings") { try $0.saveXdebug(x) }
    }
}

/// Text field values for the "add proxy" row. @State is a macro that the Command Line Tools cannot expand.
final class ProxyDraft: ObservableObject {
    @Published var name = ""
    @Published var url = ""
}

/// Composer, WP-CLI, and the Laravel installer. Corral.app holds one copy of each. An update goes to the tools folder.
/// The WordPress defaults as text until Apply.
final class WordPressDraft: ObservableObject {
    @Published var values = WordPressDefaults()
    private var loaded = false
    func loadOnce(_ wp: WordPressDefaults) { if !loaded { values = wp; loaded = true } }
}

struct ToolsTab: View {
    @ObservedObject var model: Model
    @StateObject private var wp = WordPressDraft()

    var body: some View {
        Form {
            Section {
                ForEach(Corral.tools) { tool in
                    let have = model.snap.tools[tool.name]
                    let latest = model.latestTools[tool.name]
                    let newer = latest.map { $0.compare(have?.version ?? "0", options: .numeric) == .orderedDescending } ?? false
                    LabeledContent {
                        if newer, let latest {
                            Button(have == nil ? "Install \(latest)" : "Update to \(latest)") {
                                model.run("Updating \(tool.title)") { try $0.updateTool(tool) }
                            }
                            .disabled(model.busy != nil)
                        }
                    } label: {
                        Text(have.map { "\(tool.title) \($0.version)" } ?? tool.title)
                        Text(have == nil ? "Not installed" : newer ? "Update available" : latest == nil ? (have!.updated ? "Updated copy" : "Bundled with Corral") : "Up to date")
                    }
                }
            } footer: {
                Footer("Run them in a terminal as composer, wp, and laravel, after you put Corral's bin folder in PATH.")
            }
            Section {
                TextField("Admin user", text: $wp.values.adminUser)
                TextField("Admin password", text: $wp.values.adminPassword)
                TextField("Admin email", text: $wp.values.adminEmail, prompt: Text("admin@<site>.\(model.snap.tld)"))
                TextField("Locale", text: $wp.values.locale, prompt: Text("en_US"))
                TextField("Table prefix", text: $wp.values.tablePrefix, prompt: Text("wp_"))
                LabeledContent("") {
                    HStack {
                        Button("Revert") { wp.values = model.snap.wordpress }
                        Button("Apply", action: applyWordPress)
                    }
                    .disabled(model.busy != nil || wp.values == model.snap.wordpress)
                }
            } header: {
                Text("New WordPress sites")
            } footer: {
                Footer("\"Set Up WordPress…\" and corral wp:setup use these values. The password is visible, because the site runs only on this Mac.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.checkToolUpdates(); wp.loadOnce(model.snap.wordpress) }
    }
}

extension ToolsTab {
    private func applyWordPress() {
        let values = wp.values
        if let problem = values.problem { model.error = problem; return }
        model.run("Saving WordPress defaults") { c in c.config.wordpress = values; try c.save() }
    }
}

struct SitesTab: View {
    @ObservedObject var model: Model
    @StateObject private var draft = ProxyDraft()

    var body: some View {
        Form {
            Section {
                ForEach(model.snap.parked, id: \.self) { dir in
                    LabeledContent((dir as NSString).abbreviatingWithTildeInPath) {
                        remove("Stop serving \(dir)") { c in c.config.parked.removeAll { $0 == dir } }
                    }
                }
                Button("Park Folder…", action: model.park)
            } header: {
                Text("Parked folders")
            } footer: {
                Footer("Each subfolder is a site.")
            }
            Section("Links") {
                if model.snap.links.isEmpty { Text("No linked folders. A link serves one project folder outside the parked folders.").foregroundStyle(.secondary) }
                ForEach(model.snap.links, id: \.name) { link in
                    LabeledContent {
                        remove("Remove link \(link.name)") { c in c.config.links[link.name] = nil }
                    } label: {
                        Text(link.name)
                        Text((link.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
                Button("Link Folder…", action: model.link)
            }
            Section("Proxies") {
                ForEach(model.snap.proxies, id: \.name) { proxy in
                    LabeledContent {
                        remove("Remove proxy \(proxy.name)") { c in c.config.proxies[proxy.name] = nil }
                    } label: {
                        Text(proxy.name)
                        Text(proxy.url)
                    }
                }
                HStack {
                    TextField("Name", text: $draft.name).frame(width: 120)
                    TextField("http://127.0.0.1:3000", text: $draft.url)
                    Button("Add", action: addProxy).disabled(draft.name.isEmpty || draft.url.isEmpty)
                }
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }

    private func remove(_ help: String, _ change: @escaping @Sendable (Corral) -> Void) -> some View {
        Button { model.run("Saving") { c in change(c); try c.apply() } } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func addProxy() {
        guard let url = URL(string: draft.url), ["http", "https"].contains(url.scheme), url.host != nil else {
            model.error = "Enter a URL such as http://127.0.0.1:3000."
            return
        }
        let name = Corral.slug(draft.name), target = draft.url
        model.run("Adding proxy") { c in c.config.proxies[name] = target; try c.apply() }
        draft.name = ""
        draft.url = ""
    }
}

struct CertificatesTab: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Section {
                if model.snap.certs.isEmpty { Text("No site uses HTTPS.").foregroundStyle(.secondary) }
                ForEach(model.snap.certs, id: \.host) { cert in
                    LabeledContent(cert.host) {
                        if let date = cert.expires {
                            Text("Expires \(date.formatted(date: .abbreviated, time: .omitted))")
                                .foregroundStyle(date < .now.addingTimeInterval(30 * 86400) ? .orange : .secondary)
                        } else {
                            Text("Missing").foregroundStyle(.red)
                        }
                    }
                }
            } footer: {
                Footer("Corral renews certificates that expire within 30 days when the services start.")
            }
            Section {
                LabeledContent("Expiring certificates") {
                    Button("Renew Now") { model.run("Renewing") { c in try c.renewCertificates(); try c.apply() } }
                }
                LabeledContent("Local certificate authority") {
                    Button("Trust Again") { model.run("Trusting the CA") { c in try c.ensureCA(); try c.trustCA() } }
                }
            }
            .disabled(model.busy != nil)
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    @ObservedObject var model: Model
    @AppStorage("autoUpdate") private var autoUpdate = true
    private var version: String { Corral.appVersion ?? "development build" }
    private var licenses: String? {
        Bundle.main.resourcePath.map { $0 + "/licenses" }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64) // follows dark mode
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corral").font(.title2.weight(.semibold))
                        Text("Local PHP sites on your Mac.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Version", value: version)
                Toggle("Install updates automatically", isOn: $autoUpdate)
                if let update = model.update {
                    LabeledContent("Corral \(update.version) is available.") {
                        Button("Update and Restart") { model.installUpdate() }.disabled(model.busy != nil)
                    }
                } else {
                    LabeledContent {
                        Button("Check for Updates") { model.checkForUpdate(manual: true) }.disabled(model.busy != nil || model.checkingUpdate)
                    } label: {
                        if model.checkingUpdate {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }.foregroundStyle(.secondary)
                        } else if let status = model.updateStatus {
                            Text(status).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } footer: {
                Footer("Corral looks for a new version at launch and once a day. With automatic updates on, it installs the new version and restarts. Your sites keep running.")
            }
            Section {
                LabeledContent("nginx", value: "BSD 2-Clause")
                LabeledContent("dnsmasq", value: "GPL 2 (source included)")
                LabeledContent("PHP", value: "PHP License 3.01")
                LabeledContent("Composer", value: "MIT")
                LabeledContent("WP-CLI", value: "MIT")
                LabeledContent("Laravel Installer", value: "MIT")
                if let licenses {
                    Button("Show Licence Files") { NSWorkspace.shared.open(URL(fileURLWithPath: licenses)) }
                }
            } header: {
                Text("Bundled software")
            }
        }
        .formStyle(.grouped)
    }
}
