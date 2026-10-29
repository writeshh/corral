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
        .onAppear { model.refresh() }
    }
}

/// Shows the job in progress, or the last error, under the tabs.
struct StatusLine: View {
    @ObservedObject var model: Model

    var body: some View {
        if let busy = model.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(busy)…").foregroundStyle(.secondary) }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
        } else if let error = model.error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .font(.callout).padding(.horizontal, 20).padding(.bottom, 12)
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
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
    }
}

struct PHPTab: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Section("Installed") {
                if model.snap.versions.isEmpty { Text("No PHP version is installed.").foregroundStyle(.secondary) }
                ForEach(model.snap.versions.reversed(), id: \.self) { v in
                    let managed = model.snap.managed.contains(v)
                    LabeledContent {
                        HStack {
                            if let ini = model.snap.iniPaths[v] {
                                Button("php.ini") { NSWorkspace.shared.open(URL(fileURLWithPath: ini)) }.help(ini)
                            }
                            if managed {
                                Button("Update") { model.run("Updating PHP \(v)") { try $0.installPHP(v) } }
                                Button("Remove") { model.run("Removing PHP \(v)") { try $0.uninstallPHP(v) } }
                            }
                        }
                        .disabled(model.busy != nil)
                    } label: {
                        Text("PHP \(v)")
                        Text(managed ? "Corral build" : "Homebrew")
                    }
                }
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
                                Button(v) { model.run("Installing PHP \(v)") { try $0.installPHP(v) } }
                            }
                        }
                        .disabled(model.busy != nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
