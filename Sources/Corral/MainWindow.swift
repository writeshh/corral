import SwiftUI

/// The main window, drawn with the design system: a raised sidebar with Sites and the Insights views, and the
/// content on the surface color. The quick menu and the Dock icon open it. The title bar is hidden, so the
/// window controls sit over the sidebar.
struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var insights: Insights
    @ObservedObject var mail: MailServer
    @AppStorage("mainSection") private var stored = "sites"
    @AppStorage("insightsTab") private var insightsTab = "dumps" // the last Insights view, for ⌘I
    @StateObject private var log = LogState() // here, not in LogsView, so a change of section keeps Clear
    @Environment(\.openSettings) private var openSettings

    /// The Insights views in sidebar order: section id, title, symbol.
    static let insightsSections = [
        ("dumps", "Dumps", "curlybraces"), ("queries", "Requests", "arrow.left.arrow.right"),
        ("profiles", "Profiles", "chart.bar"), ("logs", "Logs", "text.alignleft"), ("mail", "Mail", "envelope"),
    ]

    /// An unknown stored value shows Sites.
    private var section: String { Self.insightsSections.contains { $0.0 == stored } ? stored : "sites" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.border).frame(height: 1)
                Group {
                    switch section {
                    case "logs": LogsView(model: model, log: log)
                    case "mail": MailView(model: model, mail: mail)
                    case "queries": QueriesView(model: model)
                    case "profiles": ProfilesView(model: model)
                    case "dumps": DumpsView(model: model, insights: insights)
                    default: SitesView(model: model)
                    }
                }
                .buttonStyle(CorralButtonStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusLine(model: model) // jobs, errors and notices show where the user acted
            }
            .background(Color.surface)
        }
        .designSurface()
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 480)
        .onAppear { model.refresh() }
    }

    private func go(_ id: String) {
        stored = id
        if id != "sites" { insightsTab = id }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarItem(title: "Sites", symbol: "folder", trailing: String(model.snap.rows.count), active: section == "sites") { go("sites") }
            Text("Insights").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
            ForEach(Self.insightsSections, id: \.0) { id, title, symbol in
                SidebarItem(title: title, symbol: symbol, trailing: id == "mail" && !mail.messages.isEmpty ? String(mail.messages.count) : "",
                            active: section == id) { go(id) }
            }
            Spacer(minLength: 8)
            Rectangle().fill(Color.border).frame(height: 1).padding(.bottom, 6)
            HStack(spacing: 6) {
                if model.busy != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(model.statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(model.busy.map { "\($0)…" } ?? model.statusText).font(.system(size: 11)).foregroundStyle(Color.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .help(model.serviceList)
            SidebarItem(title: "Settings…", symbol: "gearshape", trailing: "⌘,", active: false) { openSettings() }
        }
        .padding(8)
        .padding(.top, 30) // room for the window controls
        .frame(width: 200)
        .background(Color.surfaceRaised)
    }

    /// The title of the view. Sites adds the filter and Park Folder.
    private var header: some View {
        HStack(spacing: 8) {
            Text(Self.insightsSections.first { $0.0 == section }?.1 ?? "Sites").font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            if section == "sites" {
                // Return opens the first match: type a few letters, press Return, and the site opens.
                SearchField(text: $model.filter) {
                    if let first = model.snap.rows.first(where: { $0.host.localizedCaseInsensitiveContains(model.filter) }) { NSWorkspace.shared.open(first.url) }
                }
                .frame(width: 240)
                Button(action: model.park) { Label("Park Folder…", systemImage: "folder.badge.plus") }.buttonStyle(CorralButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

extension View {
    /// The ground and ink of the design system for a whole window. Lists and forms inside lose their system
    /// background, so the surface shows through. Secondary text becomes a quieter ink.
    func designSurface() -> some View {
        self.foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .background(Color.surface)
            .tint(.brand)
    }
}

/// One destination in the sidebar: a symbol, a title, and a count or shortcut on the right.
struct SidebarItem: View {
    let title: String
    let symbol: String
    var trailing = ""
    let active: Bool
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Color.inkMuted).frame(width: 16)
                Text(title).font(.system(size: 13, weight: active ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? Color.surfacePressed : hover.on ? Color.surfaceHover : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The search field of the design system: a raised field with a strong edge. The text field inside is the
/// AppKit search field, which password AutoFill skips.
struct SearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.inkFaint)
            FilterField(text: $text, onSubmit: onSubmit)
            if text.isEmpty {
                Text("⌘F").font(.system(size: 11)).foregroundStyle(Color.inkFaint)
                    .padding(.horizontal, 4)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.border) }
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.inkMuted)
                    .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.surfaceRaised, in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderStrong) }
    }
}

/// The button of the design system. Default: a raised fill with a strong edge. Primary: the brand fill, one in a view.
struct CorralButtonStyle: ButtonStyle {
    var primary = false
    var danger = false // an action that removes data
    var quiet = false  // a toolbar action: no fill and no edge
    var active = false // a quiet button that is on
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let ink = primary ? Color.onBrand : danger ? Color.danger : active ? Color.brandInk : quiet ? Color.inkMuted : Color.ink
        let fill = primary ? Color.brand : configuration.isPressed ? Color.surfacePressed : quiet ? Color.clear : Color.surfaceRaised
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, quiet ? 6 : 12)
            .frame(height: 24)
            .background(fill, in: .rect(cornerRadius: 6))
            .overlay { if !quiet { RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Color.brand : Color.borderStrong) } }
            .contentShape(.rect)
            .opacity(enabled ? (configuration.isPressed && primary ? 0.85 : 1) : 0.45)
    }
}

/// The site list: one group for each parked folder. A click selects a site. A double-click opens it in the browser.
struct SitesView: View {
    @ObservedObject var model: Model
    @AppStorage("collapsedGroups") private var collapsedGroups = "" // group keys, one per line
    @AppStorage("selectedSite") private var selected = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [Snapshot.Row] {
        model.filter.isEmpty ? model.snap.rows : model.snap.rows.filter { $0.host.localizedCaseInsensitiveContains(model.filter) }
    }

    var body: some View {
        let rows = self.rows
        ScrollView {
            // No pinned section headers: they move the rows by fractions of a pixel, and the text blurs.
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.snap.rows.isEmpty {
                    EmptyState(symbol: "folder.badge.plus", title: "No sites yet",
                               text: "Park a folder that holds your projects. Corral serves each subfolder as <folder>.\(model.snap.tld).") {
                        Button("Park Folder…", action: model.park).buttonStyle(CorralButtonStyle(primary: true))
                    }
                } else if rows.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No site matches \u{201C}\(model.filter)\u{201D}",
                               text: "Check the spelling, or park the folder that holds the site.") {
                        Button("Clear Filter") { model.filter = "" }.buttonStyle(CorralButtonStyle())
                    }
                }
                let groups = self.groups(rows)
                ForEach(groups, id: \.key) { group in
                    if groups.count > 1 { groupHeader(group) }
                    if groups.count == 1 || !isCollapsed(group.key) {
                        ForEach(group.rows) { row in
                            SiteRow(row: row, model: model, selected: row.id == selected) { selected = row.id }
                        }
                    }
                }
                if !model.snap.portless.isEmpty && model.filter.isEmpty { portlessSection }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: model.snap.rows.map(\.id))
        .onAppear { model.refresh() }
        .onDisappear { model.filter = "" } // a filter left from last time would make sites look missing
    }

    /// Apps that portless serves. Corral does not serve them, so they get their own short list.
    private var portlessSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("portless").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            ForEach(model.snap.portless) { app in
                Button { NSWorkspace.shared.open(app.url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal").foregroundStyle(Color.inkMuted).frame(width: 20)
                        Text(app.host).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("localhost:\(app.port)" + (app.isAlias ? " (alias)" : "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
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
    private func groups(_ rows: [Snapshot.Row]) -> [(key: String, title: String, rows: [Snapshot.Row])] {
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
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Text(group.title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(group.rows.count)).font(.system(size: 11).monospacedDigit())
            }
            .foregroundStyle(Color.inkMuted)
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

/// An empty list: a symbol, the fact, the next step, and one button.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Color.inkFaint)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 260).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// One site as a table row: kind, name, lock, PHP version, folder, and the row actions.
struct SiteRow: View {
    let row: Snapshot.Row
    @ObservedObject var model: Model
    let selected: Bool
    let select: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        // The top level domain is quiet, so the eye reads the name first.
        let dot = row.host.lastIndex(of: ".") ?? row.host.endIndex
        HStack(spacing: 8) {
            KindTile(kind: row.kind)
            Text("\(Text(row.host[..<dot]).fontWeight(.medium))\(Text(row.host[dot...]).foregroundStyle(Color.inkMuted))")
                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            if row.secured {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.inkFaint).accessibilityLabel("HTTPS")
            }
            Spacer(minLength: 8)
            // A pinned PHP version is a badge. The global version is plain text.
            Group {
                if let pinned = row.isolated {
                    Text(pinned).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.surfacePressed, in: .rect(cornerRadius: 4))
                        .help("PHP version pinned to this site")
                } else {
                    Text(row.php ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.inkMuted)
                }
            }
            .frame(width: 48, alignment: .leading)
            Text(row.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.inkMuted)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 220, alignment: .leading)
            // The actions show on hover and on selection. The context menu has the same items.
            HStack(spacing: 2) {
                Button { NSWorkspace.shared.open(row.url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Open in Browser")
                    .accessibilityLabel("Open \(row.host) in the browser")
                Menu { menuItems } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(row.host)")
            }
            .tint(.primary)
            .frame(width: 52, alignment: .trailing)
            .opacity(hover.on || selected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(selected ? Color.brandSoft : hover.on ? Color.surfaceHover : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(row.url) }
        .onTapGesture(perform: select)
        .onHover { hover.on = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var menuItems: some View {
        SiteActions(row: row, model: model)
        Divider()
        SiteSettings(row: row, model: model)
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
                // The field exists one pass after the section changes.
                DispatchQueue.main.async {
                    guard let window = NSApp.keyWindow, let field = window.contentView?.firstSearchField else { return }
                    window.makeFirstResponder(field)
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

extension NSView {
    /// The first search field below this view, for ⌘F.
    var firstSearchField: NSSearchField? {
        (self as? NSSearchField) ?? subviews.lazy.compactMap(\.firstSearchField).first
    }
}
