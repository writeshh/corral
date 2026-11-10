import ServiceManagement
import SwiftUI

/// The settings window (⌘,), drawn with the design system: tabs at the top, then cards of rows on the surface.
/// Every change runs on Model's work queue, like the quick menu.
struct SettingsView: View {
    @ObservedObject var model: Model
    @AppStorage("settingsTab") private var tab = "general"

    static let tabs = [
        ("general", "General", "gearshape"), ("php", "PHP", "chevron.left.forwardslash.chevron.right"),
        ("tools", "Tools", "wrench.and.screwdriver"), ("sites", "Sites", "folder"),
        ("certificates", "Certificates", "lock"), ("about", "About", "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Tabs(items: Self.tabs, selection: $tab).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Color.border).frame(height: 1)
            // All pages stay alive, so a change of tab keeps the values that are not applied yet.
            ZStack {
                page("general") { GeneralTab(model: model) }
                page("php") { PHPTab(model: model) }
                page("tools") { ToolsTab(model: model) }
                page("sites") { SitesTab(model: model) }
                page("certificates") { CertificatesTab(model: model) }
                page("about") { AboutTab(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusLine(model: model)
        }
        .frame(width: 580, height: 520)
        .buttonStyle(CorralButtonStyle())
        .designSurface()
        .background(SurfaceWindow())
        .onAppear { model.refresh() }
    }

    private func page(_ id: String, @ViewBuilder _ content: () -> some View) -> some View {
        content().opacity(tab == id ? 1 : 0).allowsHitTesting(tab == id).accessibilityHidden(tab != id)
    }
}

/// Gives the window of a view the surface color under a transparent title bar, so the title bar is not system gray.
struct SurfaceWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { // the view has its window one pass later
            view.window?.titlebarAppearsTransparent = true
            view.window?.backgroundColor = .dynamic(dark: 0x1A1917, light: 0xFBFAF7)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Form parts of the design system

/// The tabs of the design system: one raised group, and the active tab on the pressed surface.
struct Tabs: View {
    let items: [(String, String, String)] // id, title, symbol
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { id, title, symbol in
                Button { selection = id } label: {
                    HStack(spacing: 6) { Image(systemName: symbol); Text(title) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == id ? Color.ink : Color.inkMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(selection == id ? Color.surfacePressed : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.surfaceRaised, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border) }
    }
}

/// A settings page: cards in a column on the surface.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A card of rows on the raised surface, with an optional title above and an optional note below.
struct Card<Content: View, Header: View, Note: View>: View {
    let content: Content
    let header: Header
    let footer: Note

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Note) {
        (self.content, self.header, self.footer) = (content(), header(), footer())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header.font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted).padding(.horizontal, 12)
            VStack(spacing: 0) { content }
                .background(Color.surfaceRaised)
                .clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border) } // also covers the hairline of the last row
            footer.padding(.horizontal, 12)
        }
    }
}

extension Card where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Note) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension Card where Note == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension Card where Header == EmptyView, Note == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension Card where Header == Text, Note == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

/// One setting: a label on the left with its help below it, and one control on the right.
struct SettingRow<Label: View, Control: View>: View {
    let control: Control
    let label: Label

    init(@ViewBuilder content: () -> Control, @ViewBuilder label: () -> Label) {
        (self.control, self.label) = (content(), label())
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) { label }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control
        }
        .settingRow()
    }
}

/// The label of a row: the title, and the help text in the quiet style.
struct RowLabel: View {
    let title: String
    var help: String?

    var body: some View {
        if !title.isEmpty { Text(title) }
        if let help { Text(help).rowHelp() }
    }
}

extension SettingRow where Label == RowLabel {
    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Control) {
        self.init(content: content, label: { RowLabel(title: title, help: help) })
    }
}

extension SettingRow where Label == RowLabel, Control == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value).foregroundStyle(Color.inkMuted) }
    }
}

extension View {
    /// The padding of a card row and the hairline under it.
    func settingRow() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    /// Help text in a row: small and quiet.
    func rowHelp() -> some View { font(.system(size: 11)).foregroundStyle(Color.inkMuted) }

    /// The text field of the design system: the surface color with a strong edge.
    func designField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.surface, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.borderStrong) }
    }
}

/// A switch with its label and help in a row.
struct ToggleRow: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool

    init(_ title: String, help: String? = nil, isOn: Binding<Bool>) {
        (self.title, self.help, self._isOn) = (title, help, isOn)
    }

    var body: some View {
        SettingRow(title, help: help) { Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(CorralToggleStyle()) }
    }
}

/// The switch of the design system: the brand color when on, the pressed surface with a strong edge when off.
struct CorralToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule().fill(on ? Color.brand : Color.surfacePressed)
            .overlay { Capsule().strokeBorder(on ? Color.brand : Color.borderStrong) }
            .frame(width: 32, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(on ? Color.onBrand : Color.inkMuted).frame(width: 12, height: 12).padding(3)
            }
            .contentShape(.capsule)
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A text field with its label and help in a row.
struct FieldRow: View {
    let title: String
    var help: String?
    @Binding var text: String
    var prompt: String?

    init(_ title: String, help: String? = nil, text: Binding<String>, prompt: String? = nil) {
        (self.title, self.help, self._text, self.prompt) = (title, help, text, prompt)
    }

    var body: some View {
        SettingRow(title, help: help) {
            TextField(title, text: $text, prompt: prompt.map { Text(verbatim: $0).foregroundStyle(Color.inkFaint) }) // verbatim: a URL must not become a link.labelsHidden().designField().frame(width: 200)
        }
    }
}

/// A menu of choices with its label in a row. The menu looks like a default button with the current choice.
struct PickerRow: View {
    let title: String
    @Binding var selection: String
    let options: [(value: String, label: String)]

    init(_ title: String, selection: Binding<String>, options: [(String, String)]) {
        (self.title, self._selection, self.options) = (title, selection, options.map { (value: $0.0, label: $0.1) })
    }

    var body: some View {
        SettingRow(title) {
            Menu {
                ForEach(options, id: \.value) { option in
                    Toggle(option.label, isOn: Binding(get: { selection == option.value }, set: { if $0 { selection = option.value } }))
                }
            } label: {
                HStack(spacing: 6) {
                    Text(options.first { $0.value == selection }?.label ?? "None")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.inkMuted)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.surface, in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.borderStrong) }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
        }
    }
}

/// A note under a card, in the quiet style.
struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).rowHelp().multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// The status of the window's work, under the tabs: the job in progress, the last error, the job that just
/// ended, or a notice. Each of the four kinds of feedback shows where the user acted, not only in the panel.
struct StatusLine: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.busy != nil || model.error != nil || model.completed != nil || model.notice != nil {
            VStack(spacing: 0) {
                Rectangle().fill(Color.border).frame(height: 1)
                Group {
                    if let busy = model.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(busy)…").foregroundStyle(.secondary) }
                    } else if let error = model.error {
                        line("exclamationmark.triangle.fill", .danger, error) { model.error = nil }
                    } else if let completed = model.completed {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success)
                            Text(completed).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else if let notice = model.notice {
                        line("info.circle.fill", Color.brand, notice) { model.notice = nil }
                    }
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            }
            .background(Color.surfaceRaised)
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
        SettingsPage {
            Card {
                ToggleRow("Open Corral at login", help: "Corral starts the services again if they ran before, and restarts a service that stops.", isOn: Binding(
                    get: { model.snap.loginItem == .enabled || model.snap.loginItem == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                if model.snap.loginItem == .requiresApproval {
                    SettingRow("Allow Corral in Login Items") {
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Card {
                ToggleRow("Show Corral in the Dock", help: "Corral always shows in the Dock and in ⌘-Tab while a Corral window is open. Turn this on to keep it there.", isOn: $showInDock)
                    .onChange(of: showInDock) { Dock.update() }
            }
            Card {
                FieldRow("Main TLD", help: "Each site answers <site>.<TLD> for every TLD.", text: $domains.tld)
                FieldRow("Extra TLDs", help: "Separate the names with commas. A site can add more names with \"domains\" in .corral.json.", text: $domains.aliases, prompt: "internal, localhost")
                let unchanged = domains.tld == model.snap.tld && domains.aliases == model.snap.aliases.joined(separator: ", ")
                SettingRow(unchanged ? "" : "Changes not applied", help: "Corral asks for your password to update /etc/resolver.") {
                    Button("Apply", action: applyDomains).disabled(model.busy != nil || unchanged)
                }
            } header: {
                Text("Domains")
            }
            if model.snap.herdFound { // the same rules as the switch in the panel's menu
                Card {
                    ToggleRow("Serve .test instead of Herd", help: "Quit Herd first. Herd takes .test back while it runs.", isOn: Binding(
                        get: { model.snap.ownsTest },
                        set: { on in
                            if on { model.run("Taking over .test") { try $0.takeover() } }
                            else { model.run("Giving .test back") { try $0.runAsAdmin($0.handbackScript()) } }
                        }
                    ))
                }
                .disabled(model.snap.tld == Corral.sharedTLD)
            }
            Card {
                SettingRow("Services") {
                    Button("Restart") { model.run("Restarting") { c in c.stop(); try c.start() } }.disabled(!model.running)
                }
                SettingRow("Config folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.snap.home)) }
                }
            }
        }
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
        SettingsPage {
            Card("Installed") {
                if model.snap.versions.isEmpty { Text("No PHP version is installed.").foregroundStyle(.secondary).settingRow() }
                ForEach(model.snap.versions.reversed(), id: \.self) { v in
                    let full = model.snap.builds[v]
                    let latest = model.latestPHP[v]
                    let newer = latest.map { $0.compare(full ?? v, options: .numeric) == .orderedDescending } ?? false
                    SettingRow {
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
                                .buttonStyle(CorralButtonStyle(danger: true))
                        }
                        .disabled(model.busy != nil)
                    } label: {
                        Text("PHP \(full ?? v)")
                        Text(newer ? "Update available" : latest == nil ? "Corral build" : "Up to date").rowHelp()
                    }
                }
                PickerRow("Settings for", selection: Binding(get: { settings.version ?? "" }, set: { settings.switchTo($0, model.snap) }),
                          options: model.snap.versions.reversed().map { ($0, "PHP \($0)") })
            }
            if let version = settings.version, model.snap.versions.contains(version) {
                PHPSettingsSections(model: model, settings: settings, version: version)
            }
            XdebugSection(model: model, draft: xdebug)
            Card {
                PickerRow("Global version", selection: Binding(
                    get: { model.snap.globalPHP ?? "" },
                    set: { v in model.run("Switching PHP") { c in c.config.php = v; try c.apply() } }
                ), options: model.snap.versions.map { ($0, "PHP \($0)") })
                let missing = Corral.phpChoices.filter { !model.snap.versions.contains($0) }
                if !missing.isEmpty {
                    SettingRow("Install") {
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
        Card {
            FieldRow("Memory limit", text: settings.binding("memory_limit"), prompt: "1024M, or -1 for no limit")
            FieldRow("Maximum upload size", text: settings.binding("upload_max_filesize"), prompt: "512M")
            FieldRow("Maximum execution time (seconds)", text: settings.binding("max_execution_time"), prompt: "600")
            FieldRow("Maximum input variables", text: settings.binding("max_input_vars"), prompt: "1000")
            ToggleRow("Display errors", isOn: settings.flag("display_errors"))
            FieldRow("Error reporting", text: settings.binding("error_reporting"), prompt: "E_ALL")
            FieldRow("Time zone", text: settings.binding("date.timezone"), prompt: "UTC")
            ToggleRow("OPcache", isOn: settings.flag("opcache.enable"))
            FieldRow("Output buffering (bytes)", text: settings.binding("output_buffering"), prompt: "4096")
        } header: {
            Text("PHP \(version) settings")
        }
        Card {
            PickerRow("Process manager", selection: $settings.pool.pm, options: [("dynamic", "Dynamic"), ("ondemand", "On demand"), ("static", "Static")])
            FieldRow("Maximum processes", text: settings.number(\.maxChildren))
            FieldRow("Request timeout (seconds, 0 = none)", text: settings.number(\.requestTerminateTimeout))
            FieldRow("Slow log after (seconds, 0 = off)", text: settings.number(\.slowlogTimeout))
        } header: {
            Text("PHP-FPM")
        }
        // One Apply for both sections above, in its own row, so it is clear that it saves both.
        Card {
            SettingRow(settings.changed(model.snap) ? "PHP \(version) has changes that are not applied" : "") {
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
        Card {
            ToggleRow("Debug pool (Xdebug)", isOn: $draft.enabled)
            Group { // the pool's settings do nothing while the pool is off
                FieldRow("Mode", text: $draft.mode, prompt: "debug,develop")
                FieldRow("Client host", text: $draft.host, prompt: "127.0.0.1")
                FieldRow("Client port", text: $draft.port, prompt: "9003")
            }
            .disabled(!draft.enabled)
            PickerRow("Start a session", selection: $draft.start, options: [("yes", "For every request in the pool"), ("trigger", "Only with XDEBUG_TRIGGER")])
                .disabled(!draft.enabled || draft.profile)
            ToggleRow("Profiler (XDEBUG_PROFILE)", isOn: $draft.profile).disabled(!draft.enabled)
            ToggleRow("Use the pool while the editor listens", isOn: $draft.detect).disabled(!draft.enabled)
                .help("While a program listens on the client port on this Mac, every PHP request runs with Xdebug, without a cookie.")
            SettingRow(draft.settings() == model.snap.xdebug ? "" : "Changes not applied") {
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
@MainActor
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
        SettingsPage {
            Card {
                ForEach(Corral.tools) { tool in
                    let have = model.snap.tools[tool.name]
                    let latest = model.latestTools[tool.name]
                    let newer = latest.map { $0.compare(have?.version ?? "0", options: .numeric) == .orderedDescending } ?? false
                    SettingRow {
                        if newer, let latest {
                            Button(have == nil ? "Install \(latest)" : "Update to \(latest)") {
                                model.run("Updating \(tool.title)") { try $0.updateTool(tool) }
                            }
                            .disabled(model.busy != nil)
                        }
                    } label: {
                        Text(have.map { "\(tool.title) \($0.version)" } ?? tool.title)
                        Text(have == nil ? "Not installed" : newer ? "Update available" : latest == nil ? (have!.updated ? "Updated copy" : "Bundled with Corral") : "Up to date").rowHelp()
                    }
                }
            } footer: {
                Footer("Run them in a terminal as composer, wp, and laravel, after you put Corral's bin folder in PATH.")
            }
            Card {
                FieldRow("Admin user", text: $wp.values.adminUser)
                FieldRow("Admin password", text: $wp.values.adminPassword)
                FieldRow("Admin email", text: $wp.values.adminEmail, prompt: "admin@<site>.\(model.snap.tld)")
                FieldRow("Locale", text: $wp.values.locale, prompt: "en_US")
                FieldRow("Table prefix", text: $wp.values.tablePrefix, prompt: "wp_")
                SettingRow(wp.values == model.snap.wordpress ? "" : "Changes not applied") {
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
        SettingsPage {
            Card {
                ForEach(model.snap.parked, id: \.self) { dir in
                    SettingRow((dir as NSString).abbreviatingWithTildeInPath) {
                        remove("Stop serving \(dir)") { c in c.config.parked.removeAll { $0 == dir } }
                    }
                }
                SettingRow("Serve the subfolders of one more folder") { Button("Park Folder…", action: model.park) }
            } header: {
                Text("Parked folders")
            }
            Card("Links") {
                if model.snap.links.isEmpty { Text("No linked folders. A link serves one project folder outside the parked folders.").foregroundStyle(.secondary).settingRow() }
                ForEach(model.snap.links, id: \.name) { link in
                    SettingRow {
                        remove("Remove link \(link.name)") { c in c.config.links[link.name] = nil }
                    } label: {
                        Text(link.name)
                        Text((link.path as NSString).abbreviatingWithTildeInPath).rowHelp()
                    }
                }
                SettingRow("Serve one project folder") { Button("Link Folder…", action: model.link) }
            }
            Card("Proxies") {
                ForEach(model.snap.proxies, id: \.name) { proxy in
                    SettingRow {
                        remove("Remove proxy \(proxy.name)") { c in c.config.proxies[proxy.name] = nil }
                    } label: {
                        Text(proxy.name)
                        Text(proxy.url).rowHelp()
                    }
                }
                HStack {
                    TextField("Proxy name", text: $draft.name, prompt: Text("name").foregroundStyle(Color.inkFaint)).designField().frame(width: 120)
                    TextField("Proxy URL", text: $draft.url, prompt: Text(verbatim: "http://127.0.0.1:3000").foregroundStyle(Color.inkFaint)).designField()
                    Button("Add", action: addProxy).disabled(draft.name.isEmpty || draft.url.isEmpty)
                }
                .labelsHidden()
                .settingRow()
            }
        }
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
        let draft = draft
        model.run("Adding proxy \(name)") { c in
            c.config.proxies[name] = target
            try c.apply()
            // Clear the fields only after the proxy is saved: after an error, the user fixes the text, not types it again.
            Task { @MainActor in draft.name = ""; draft.url = "" }
        }
    }
}

struct CertificatesTab: View {
    @ObservedObject var model: Model

    var body: some View {
        SettingsPage {
            Card {
                if model.snap.certs.isEmpty { Text("No site uses HTTPS.").foregroundStyle(.secondary).settingRow() }
                ForEach(model.snap.certs, id: \.host) { cert in
                    SettingRow(cert.host) {
                        if let date = cert.expires {
                            Text("Expires \(date.formatted(date: .abbreviated, time: .omitted))")
                                .foregroundStyle(date < .now.addingTimeInterval(30 * 86400) ? Color.warning : Color.inkMuted)
                        } else {
                            Text("Missing").foregroundStyle(Color.danger)
                        }
                    }
                }
            } footer: {
                Footer("Corral renews certificates that expire within 30 days when the services start.")
            }
            Card {
                SettingRow("Expiring certificates") {
                    Button("Renew Now") { model.run("Renewing") { c in try c.renewCertificates(); try c.apply() } }
                }
                SettingRow("Local certificate authority") {
                    Button("Trust Again") { model.run("Trusting the CA") { c in try c.ensureCA(); try c.trustCA() } }
                }
            }
            .disabled(model.busy != nil)
        }
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
        SettingsPage {
            Card {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64) // follows dark mode
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corral").font(.system(size: 15, weight: .semibold))
                        Text("Local PHP sites on your Mac.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .settingRow()
            }
            Card {
                SettingRow("Version", value: version)
                ToggleRow("Install updates automatically", isOn: $autoUpdate)
                if let update = model.update {
                    SettingRow("Corral \(update.version) is available.") {
                        Button("Update and Restart") { model.installUpdate() }.disabled(model.busy != nil)
                    }
                } else {
                    SettingRow {
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
            Card {
                SettingRow("nginx", value: "BSD 2-Clause")
                SettingRow("dnsmasq", value: "GPL 2 (source included)")
                SettingRow("PHP", value: "PHP License 3.01")
                SettingRow("Composer", value: "MIT")
                SettingRow("WP-CLI", value: "MIT")
                SettingRow("Laravel Installer", value: "MIT")
                if let licenses {
                    SettingRow("License files") { Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: licenses)) } }
                }
            } header: {
                Text("Bundled software")
            }
        }
    }
}
