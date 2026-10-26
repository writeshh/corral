import SwiftUI

@MainActor
final class Model: ObservableObject {
    let corral = Corral()
    @Published var sites: [Site] = []
    @Published var status: [(String, Bool)] = []
    @Published var versions: [String] = []

    var running: Bool { status.first?.1 ?? false }

    init() { refresh() }

    func refresh() {
        sites = corral.sites()
        status = corral.status()
        versions = Corral.sortVersions(corral.phpVersions().keys)
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Corral"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    func park() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Park"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            if !corral.config.parked.contains(url.path) { corral.config.parked.append(url.path) }
            try corral.apply()
        }
    }
}

struct CorralApp: App {
    @StateObject private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) } // no Dock icon when run from a terminal

    var body: some Scene {
        MenuBarExtra("Corral", systemImage: model.running ? "circle.hexagongrid.fill" : "circle.hexagongrid") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: Model
    private var corral: Corral { model.corral }

    var body: some View {
        ForEach(model.status, id: \.0) { name, up in Text("\(up ? "●" : "○")  \(name)") }
        if !corral.isInstalled {
            Button("Install Networking… (admin)") { model.perform { try corral.runAsAdmin(corral.installScript()) } }
        }
        Button(model.running ? "Restart" : "Start") {
            model.perform {
                if model.running { corral.stop() }
                try corral.start()
            }
        }
        Button("Stop") { model.perform { corral.stop() } }.disabled(!model.running)
        Divider()

        Menu("Sites (\(model.sites.count))") {
            ForEach(model.sites) { site in
                Menu(corral.host(site)) {
                    Button("Open in Browser") { NSWorkspace.shared.open(corral.url(site)) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: site.path)]) }
                    Toggle("HTTPS", isOn: Binding(
                        get: { corral.config.secured.contains(site.name) },
                        set: { on in model.perform { try corral.setSecure(site, on) } }
                    ))
                    Picker("PHP", selection: Binding(
                        get: { corral.config.isolated[site.name] ?? "" },
                        set: { v in model.perform {
                            corral.config.isolated[site.name] = v.isEmpty ? nil : v
                            try corral.apply()
                        } }
                    )) {
                        Text("Global").tag("")
                        ForEach(model.versions, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        }
        Picker("Global PHP", selection: Binding(
            get: { corral.globalPHP(corral.phpVersions()) ?? "" },
            set: { v in model.perform {
                corral.config.php = v
                try corral.apply()
            } }
        )) {
            ForEach(model.versions, id: \.self) { Text($0).tag($0) }
        }
        let missing = Corral.phpChoices.filter { !model.versions.contains($0) }
        if !missing.isEmpty {
            Menu("Install PHP") {
                ForEach(missing, id: \.self) { v in Button("PHP \(v)") { model.perform { try corral.installPHP(v) } } }
            }
        }
        Button("Park Folder…") { model.park() }
        Divider()
        Button("Open Config Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: corral.home)) }
        Button("Refresh") { model.refresh() }
        Button("Quit Corral") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
