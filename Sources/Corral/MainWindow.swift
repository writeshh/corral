import SwiftUI

/// The main window: a sidebar with Sites and the Insights views. The quick menu and the Dock icon open it.
struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var insights: Insights
    @ObservedObject var mail: MailServer
    @AppStorage("mainSection") private var section = "sites"
    @AppStorage("insightsTab") private var insightsTab = "dumps" // the last Insights view, for ⌘I
    @StateObject private var log = LogState() // here, not in LogsView, so a change of section keeps Clear
    @Environment(\.openSettings) private var openSettings

    /// The Insights views in sidebar order: section id, title, symbol.
    static let insightsSections = [
        ("dumps", "Dumps", "curlybraces"), ("queries", "Requests", "arrow.left.arrow.right"),
        ("profiles", "Profiles", "chart.bar"), ("logs", "Logs", "text.alignleft"), ("mail", "Mail", "envelope"),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(get: { section }, set: { new in
                guard let new else { return } // a click on empty space keeps the section
                section = new
                if new != "sites" { insightsTab = new }
            })) {
                Label("Sites", systemImage: "folder").badge(model.snap.rows.count).tag("sites")
                Section("Insights") {
                    ForEach(Self.insightsSections, id: \.0) { id, title, symbol in
                        Label(title, systemImage: symbol).badge(id == "mail" ? mail.messages.count : 0).tag(id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        } detail: {
            VStack(spacing: 0) {
                switch section {
                case "logs": LogsView(model: model, log: log)
                case "mail": MailView(model: model, mail: mail)
                case "queries": QueriesView(model: model)
                case "profiles": ProfilesView(model: model)
                case "dumps": DumpsView(model: model, insights: insights)
                default: SitesView(model: model)
                }
                StatusLine(model: model) // jobs, errors and notices show where the user acted
            }
            .navigationTitle(Self.insightsSections.first { $0.0 == section }?.1 ?? "Sites")
        }
        .frame(minWidth: 760, minHeight: 440)
        .tint(.brand)
    }

    /// The service status and the way to Settings, at the bottom of the sidebar.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(model.statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .help(model.serviceList)
            Button { openSettings() } label: { Label("Settings…", systemImage: "gearshape") }
                .buttonStyle(.borderless)
                .tint(.primary)
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
    }
}

/// The site list: one group for each parked folder, with a filter in the toolbar.
struct SitesView: View {
    @ObservedObject var model: Model
    @AppStorage("collapsedGroups") private var collapsedGroups = "" // group keys, one per line
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [Snapshot.Row] {
        model.filter.isEmpty ? model.snap.rows : model.snap.rows.filter { $0.host.localizedCaseInsensitiveContains(model.filter) }
    }

    var body: some View {
        ScrollView {
            // No pinned section headers: they move the rows by fractions of a pixel, and the text blurs.
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.snap.rows.isEmpty { empty } else if rows.isEmpty { noMatch }
                let groups = self.groups
                ForEach(groups, id: \.key) { group in
                    if groups.count > 1 { groupHeader(group) }
                    if groups.count == 1 || !isCollapsed(group.key) {
                        ForEach(group.rows) { row in SiteRow(row: row, model: model) }
                    }
                }
                if !model.snap.portless.isEmpty && model.filter.isEmpty { portlessSection }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $model.filter, prompt: "Filter sites")
        // Return opens the first match: type a few letters, press Return, and the site opens.
        .onSubmit(of: .search) { if let first = rows.first { NSWorkspace.shared.open(first.url) } }
        .toolbar { Button(action: model.park) { Label("Park Folder…", systemImage: "folder.badge.plus") }.help("Park Folder") }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.snap.rows.map(\.id))
        .onAppear { model.refresh() }
        .onDisappear { model.filter = "" } // a filter left from last time would make sites look missing
    }

    private var empty: some View {
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
    }

    private var noMatch: some View {
        VStack(spacing: 6) {
            Text("No site matches \u{201C}\(model.filter)\u{201D}").foregroundStyle(.secondary)
            Button("Clear Filter") { model.filter = "" }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    /// Apps that portless serves. Corral does not serve them, so they get their own short list.
    private var portlessSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("portless").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            ForEach(model.snap.portless) { app in
                Button { NSWorkspace.shared.open(app.url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal").foregroundStyle(.secondary).frame(width: 20)
                        Text(app.host).font(.body.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("localhost:\(app.port)" + (app.isAlias ? " (alias)" : "")).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in Browser") { NSWorkspace.shared.open(app.url) }
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.url.absoluteString, forType: .string)
                        model.confirm("Copied \(app.url.absoluteString)")
                    }
                }
                .help("Open \(app.url.absoluteString)")
            }
        }
    }

    /// Sites under the parked folder that holds them, in parked order. Linked folders and proxies come last.
    private var groups: [(key: String, title: String, rows: [Snapshot.Row])] {
        var byKey: [String: [Snapshot.Row]] = [:]
        for row in rows {
            let parent = (row.site.path as NSString).deletingLastPathComponent
            let key = row.site.proxy != nil ? "Proxies" : model.snap.parked.contains(parent) ? parent : "Linked"
            byKey[key, default: []].append(row)
        }
        return (model.snap.parked + ["Linked", "Proxies"]).compactMap { key in
            byKey[key].map { (key: key, title: key.hasPrefix("/") ? (key as NSString).lastPathComponent : key, rows: $0) }
        }
    }

    /// A filter shows every group, so a match never hides in a collapsed one.
    private func isCollapsed(_ key: String) -> Bool {
        model.filter.isEmpty && collapsedGroups.split(separator: "\n").contains { $0 == key }
    }

    private func toggle(_ key: String) {
        var keys = Set(collapsedGroups.split(separator: "\n").map(String.init))
        if keys.remove(key) == nil { keys.insert(key) }
        collapsedGroups = keys.sorted().joined(separator: "\n")
    }

    private func groupHeader(_ group: (key: String, title: String, rows: [Snapshot.Row])) -> some View {
        let collapsed = isCollapsed(group.key)
        return Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)) { toggle(group.key) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(group.rows.count)).font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.filter.isEmpty)
        .accessibilityLabel("\(group.title), \(group.rows.count) sites")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .help(group.key.hasPrefix("/") ? (group.key as NSString).abbreviatingWithTildeInPath : group.title)
    }
}

/// The app menu. It shows while a Corral window is open. The commands of the quick menu are here with the same shortcuts.
struct AppCommands: Commands {
    @ObservedObject var model: Model
    @AppStorage("mainSection") private var section = "sites"
    @AppStorage("insightsTab") private var insightsTab = "dumps"

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Park Folder…", action: model.park).keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Link Folder…", action: model.link).keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Filter Sites") {
                section = "sites"
                // The search field of .searchable is a toolbar item. It exists one pass after the section changes.
                DispatchQueue.main.async {
                    let items = NSApp.keyWindow?.toolbar?.items ?? []
                    items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
                }
            }
            .keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            Button("Sites") { section = "sites" }.keyboardShortcut("1")
            ForEach(Array(MainView.insightsSections.enumerated()), id: \.offset) { index, item in
                Button(item.1) { section = item.0; insightsTab = item.0 }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))))
            }
            Button("Insights") { section = insightsTab }.keyboardShortcut("i")
            Divider()
        }
        CommandMenu("Services") {
            Button(model.running ? "Stop Services" : "Start Services", action: model.toggleServices).disabled(model.busy != nil)
            Button("Restart Services", action: model.restartServices).keyboardShortcut("r").disabled(!model.running)
            Divider()
            GlobalPHPMenu(model: model)
            Divider()
            Button("Show Config Folder in Finder", action: model.showConfigFolder)
        }
    }
}
