import SwiftUI

/// One profiler file from the debug pool: cachegrind.out.<seconds>.<microseconds>.<host><uri>.
/// Xdebug writes _ for each / ? & . : and space of the host and the URI.
struct Profile: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int
    var id: URL { url }

    /// "shop_test_orders_5": the host and the URI, as Xdebug wrote them in the name.
    var label: String {
        let name = url.lastPathComponent
        return name.wholeMatch(of: /cachegrind\.out\.\d+\.\d+\.(.*)/).map { String($0.1) } ?? name
    }
}

extension Corral {
    var profilesDir: String { home + "/profiles" }

    /// Newest first.
    func profiles() -> [Profile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: profilesDir), includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("cachegrind.out.") }
            .compactMap { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return Profile(url: url, date: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
    }

    /// Profiler cleanup: deletes files older than maxAge, then the oldest ones until the rest fit in maxBytes.
    @discardableResult
    func cleanProfiles(maxAge: TimeInterval = 7 * 86400, maxBytes: Int = 1 << 30, now: Date = .now) -> Int {
        var total = 0, deleted = 0
        for p in profiles() {
            total += p.size
            guard now.timeIntervalSince(p.date) > maxAge || total > maxBytes else { continue }
            try? FileManager.default.removeItem(at: p.url)
            deleted += 1
        }
        return deleted
    }

    /// Requests the URL with an XDEBUG_PROFILE cookie and returns the file that the request wrote.
    func profile(_ url: String) throws -> Profile {
        guard config.xdebug.enabled && config.xdebug.profile else {
            throw CorralError("The profiler is off. Turn it on with: corral xdebug on --profile on")
        }
        let before = Set(profiles().map(\.url))
        let status = try Self.sh("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "300", "-b", "XDEBUG_PROFILE=1", url])
        // Xdebug writes the file when the request ends, which can be just after the response.
        for _ in 0..<20 {
            if let new = profiles().first(where: { !before.contains($0.url) }) { return new }
            usleep(100_000)
        }
        throw CorralError("The request (HTTP \(status)) wrote no profile. Is \(url) a Corral site with a PHP build that has Xdebug?")
    }
}

/// The profiler files, newest first. Reads the folder every 2 seconds while the tab is open.
@MainActor
final class ProfileList: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published var error: String?
    private var timer: Timer?

    func follow() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }

    func unfollow() { timer?.invalidate(); timer = nil }

    func reload() {
        let c = Corral()
        c.cleanProfiles()
        let found = c.profiles()
        if found != profiles { profiles = found }
    }

    /// To the Trash, not deleted: a profile is easy to lose and slow to make again. The Trash is the undo.
    func delete(_ p: Profile) { try? FileManager.default.trashItem(at: p.url, resultingItemURL: nil); reload() }

    func clear() { for p in profiles { try? FileManager.default.trashItem(at: p.url, resultingItemURL: nil) }; reload() }

    /// Opens the file in the app that the Mac uses for it. Cachegrind files have no standard app, so say which ones work.
    func open(_ p: Profile) {
        if NSWorkspace.shared.urlForApplication(toOpen: p.url) != nil { NSWorkspace.shared.open(p.url); return }
        error = "No app on this Mac opens cachegrind files. Install qcachegrind (brew install qcachegrind), or use PhpStorm: Tools > Analyze Xdebug Profiler Snapshot."
    }
}

struct ProfilesView: View {
    @ObservedObject var model: Model
    @StateObject private var list = ProfileList()

    private var on: Bool { model.snap.xdebug.enabled && model.snap.xdebug.profile }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Profiler", isOn: Binding(get: { on }, set: setProfiler))
                    .help("Requests with an XDEBUG_PROFILE cookie or query argument run in the debug pool and write a cachegrind file.")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(list.profiles.reduce(0) { $0 + $1.size }), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: Corral().profilesDir)) }
                Button("Move All to Trash", action: list.clear).disabled(list.profiles.isEmpty)
            }
            .padding(10)
            if let error = list.error {
                Banner(error: true, title: error, dismiss: { list.error = nil }).padding(.horizontal, 10).padding(.bottom, 10)
            }
            Divider()
            if list.profiles.isEmpty {
                ContentUnavailableView("No profiles yet", systemImage: "gauge.with.dots.needle.33percent", description: Text(on
                    ? "Add ?XDEBUG_PROFILE=1 to a URL, set an XDEBUG_PROFILE cookie, or run corral profile <url>. Corral deletes profiles after 7 days, and the oldest ones above 1 GB."
                    : "Turn on the profiler first. It needs a PHP build with Xdebug."))
                    .frame(maxHeight: .infinity)
            } else {
                List(list.profiles) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text("\(p.date.formatted(date: .abbreviated, time: .standard)) · \(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { list.open(p) }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
                        Button { list.delete(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Move to Trash").accessibilityLabel("Move to Trash")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear(perform: list.follow)
        .onDisappear(perform: list.unfollow)
    }

    /// The profiler runs in the debug pool, so turning it on also turns on the pool.
    private func setProfiler(_ on: Bool) {
        var x = model.snap.xdebug
        x.profile = on
        if on { x.enabled = true }
        let settings = x
        model.run(on ? "Turning on the profiler" : "Turning off the profiler") { try $0.saveXdebug(settings) }
    }
}
