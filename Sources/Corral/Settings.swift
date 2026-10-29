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
                SitesTab(model: model).tabItem { Label("Sites", systemImage: "folder") }
                CertificatesTab(model: model).tabItem { Label("Certificates", systemImage: "lock") }
                AboutTab().tabItem { Label("About", systemImage: "info.circle") }
            }
            StatusLine(model: model)
        }
        .frame(width: 580, height: 460)
        .tint(.brand)
        .onAppear { model.refresh() }
    }
}

/// Shows the job in progress, or the last error, under the tabs.
struct StatusLine: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.busy != nil || model.error != nil {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if let busy = model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(busy)…").foregroundStyle(.secondary) }
                    } else if let error = model.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
                        }
                    }
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(.bar)
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
                Text("Corral starts the services again if they ran before, and restarts a service that stops.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Corral in the Dock", isOn: $showInDock).onChange(of: showInDock) { Dock.update() }
            } footer: {
                Text("Corral always shows in the Dock and in ⌘-Tab while a Corral window is open. Turn this on to keep it there.").foregroundStyle(.secondary)
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
                Text("Each site answers <site>.<TLD> for every TLD. A site can add more names with \"domains\" in .corral.json. Corral asks for your password to update /etc/resolver.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Serve .test instead of Herd", isOn: Binding(
                    get: { model.snap.ownsTest },
                    set: { on in
                        if on { model.run("Taking over .test") { try $0.takeover() } }
                        else { model.run("Giving .test back") { try $0.runAsAdmin($0.handbackScript()) } }
                    }
                ))
            } footer: {
                Text("Quit Herd first. Herd takes .test back while it runs.").foregroundStyle(.secondary)
            }
            .disabled(model.snap.tld == Corral.sharedTLD)
            Section {
                LabeledContent("Services") {
                    Button("Restart") { model.run("Restarting") { c in c.stop(); try c.start() } }.disabled(!model.running)
                }
                LabeledContent("Configuration") {
                    Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.snap.home)) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { domains.tld = model.snap.tld; domains.aliases = model.snap.aliases.joined(separator: ", ") }
    }

    private func applyDomains() {
        let label = /^[a-z0-9-]+$/
        let tld = domains.tld.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases = domains.aliases.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
                            }
                            Button("Remove") { model.run("Removing PHP \(v)") { try $0.uninstallPHP(v) } }
                        }
                        .disabled(model.busy != nil)
                    } label: {
                        Text("PHP \(full ?? v)")
                        Text(newer ? "Update available" : latest == nil ? "Corral build" : "Up to date")
                    }
                }
                Picker("Settings for", selection: Binding(get: { settings.version ?? "" }, set: { settings.load($0, model.snap) })) {
                    ForEach(model.snap.versions.reversed(), id: \.self) { Text("PHP \($0)").tag($0) }
                }
            }
            if let version = settings.version, model.snap.versions.contains(version) {
                PHPSettingsSections(model: model, settings: settings, version: version)
            }
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
            LabeledContent("") {
                HStack {
                    Button("Revert") { settings.load(version, model.snap) }
                    Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                }
                .disabled(model.busy != nil || (settings.ini == model.snap.ini[version] ?? [:] && settings.pool == model.snap.pools[version]))
            }
        } header: {
            Text("PHP-FPM")
        } footer: {
            Text("Corral checks the values with PHP before it saves them, then reloads PHP \(version). A site can set its own values with \"php\" in .corral.json.")
                .foregroundStyle(.secondary)
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

/// Text field values for the "add proxy" row. @State is a macro that the Command Line Tools cannot expand.
final class ProxyDraft: ObservableObject {
    @Published var name = ""
    @Published var url = ""
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
                Button("Add Folder…", action: model.park)
            } header: {
                Text("Parked folders")
            } footer: {
                Text("Each subfolder is a site.").foregroundStyle(.secondary)
            }
            Section("Links") {
                if model.snap.links.isEmpty { Text("Run corral link in a project folder.").foregroundStyle(.secondary) }
                ForEach(model.snap.links, id: \.name) { link in
                    LabeledContent {
                        remove("Remove link \(link.name)") { c in c.config.links[link.name] = nil }
                    } label: {
                        Text(link.name)
                        Text((link.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
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
                Text("Corral renews certificates that expire within 30 days when the services start.").foregroundStyle(.secondary)
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
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }
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
                LabeledContent("Telemetry", value: "None")
            }
            Section {
                LabeledContent("nginx", value: "BSD 2-Clause")
                LabeledContent("dnsmasq", value: "GPL 2 (source included)")
                LabeledContent("PHP", value: "PHP License 3.01")
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
