import Foundation

/// A command line tool that Corral ships as a PHP archive (phar): Corral.app holds one copy,
/// and an update goes to `<home>/tools`. The shim in bin/ runs the updated copy when there is one.
struct Tool: Equatable, Sendable, Identifiable {
    let name: String   // the command in bin/
    let file: String
    let title: String
    var id: String { name }
}

extension Corral {
    static let tools = [
        Tool(name: "composer", file: "composer.phar", title: "Composer"),
        Tool(name: "wp", file: "wp-cli.phar", title: "WP-CLI"),
        Tool(name: "laravel", file: "laravel.phar", title: "Laravel Installer"),
    ]

    struct ToolRelease: Equatable, Sendable { let version: String, url: String, sha256: String }

    var toolsDir: String { home + "/tools" }

    /// versions.json maps a tool name to {"version", "sha256"}.
    static func toolVersions(in dir: String?) -> [String: String] {
        guard let dir, let data = FileManager.default.contents(atPath: dir + "/versions.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
        return json.compactMapValues { $0["version"] }
    }

    /// The version that `bin/<tool>` runs, and whether it is an updated copy. Nil when the tool is not installed.
    func installedTool(_ tool: Tool) -> (version: String, updated: Bool)? {
        let fm = FileManager.default
        if fm.fileExists(atPath: toolsDir + "/" + tool.file), let v = Self.toolVersions(in: toolsDir)[tool.name] { return (v, true) }
        guard let dir = Self.pharDir, fm.fileExists(atPath: dir + "/" + tool.file), let v = Self.toolVersions(in: dir)[tool.name] else { return nil }
        return (v, false)
    }

    // MARK: Newest releases

    /// getcomposer.org/versions: {"stable": [{"version", "path"}, ...]}, newest first.
    static func composerRelease(_ json: String, sha256sum: (String) throws -> String) throws -> ToolRelease {
        guard let data = json.data(using: .utf8), let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (top["stable"] as? [[String: Any]])?.first, let version = first["version"] as? String,
              let path = first["path"] as? String else { throw CorralError("Could not read the Composer release list.") }
        let url = "https://getcomposer.org" + path
        return ToolRelease(version: version, url: url, sha256: try sha256sum(url + ".sha256sum"))
    }

    /// The GitHub API answer for wp-cli/wp-cli releases/latest.
    static func wpRelease(_ json: String, sha256sum: (String) throws -> String) throws -> ToolRelease {
        guard let data = json.data(using: .utf8), let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = top["tag_name"] as? String, tag.range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw CorralError("Could not read the WP-CLI release.")
        }
        let version = String(tag.dropFirst())
        let url = "https://github.com/wp-cli/wp-cli/releases/download/\(tag)/wp-cli-\(version).phar"
        return ToolRelease(version: version, url: url, sha256: try sha256sum(url + ".sha256"))
    }

    /// manifest.json of the "tools" release: {"laravel": {"version", "file", "sha256"}}.
    static func laravelRelease(_ json: String, base: String) throws -> ToolRelease {
        guard let data = json.data(using: .utf8), let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = top["laravel"] as? [String: String], let version = m["version"], let file = m["file"], let sha = m["sha256"],
              !file.contains("/") else { throw CorralError("Could not read the Laravel installer release.") }
        return ToolRelease(version: version, url: base + "/" + file, sha256: sha)
    }

    /// The first word of a checksum file: "<sha256>  composer.phar".
    private static func checksum(of url: String) throws -> String {
        let text = try sh("/usr/bin/curl", ["-fsSL", url])
        guard let word = text.split(whereSeparator: \.isWhitespace).first, word.count == 64 else { throw CorralError("Bad checksum file: \(url)") }
        return String(word).lowercased()
    }

    func latestRelease(_ tool: Tool) throws -> ToolRelease {
        let get = { try Self.sh("/usr/bin/curl", ["-fsSL", "-H", "Accept: application/vnd.github+json", $0]) }
        switch tool.name {
        case "composer": return try Self.composerRelease(try get("https://getcomposer.org/versions"), sha256sum: Self.checksum)
        case "wp": return try Self.wpRelease(try get("https://api.github.com/repos/wp-cli/wp-cli/releases/latest"), sha256sum: Self.checksum)
        default:
            let base = ProcessInfo.processInfo.environment["CORRAL_TOOLS_URL"] ?? "https://github.com/writeshh/corral/releases/download/tools"
            guard let json = try? get(base + "/manifest.json") else {
                throw CorralError("Could not read \(base)/manifest.json. Check your network connection. The release has no installer until the Tools workflow has run on GitHub.")
            }
            return try Self.laravelRelease(json, base: base)
        }
    }

    // MARK: Install

    /// Downloads the phar, checks its SHA-256, and puts it in tools/. The shim runs that copy from now on.
    func installTool(_ tool: Tool, _ release: ToolRelease) throws {
        let fm = FileManager.default
        try mkdirs(toolsDir)
        let temp = toolsDir + "/" + tool.file + ".download"
        defer { try? fm.removeItem(atPath: temp) }
        try sh("/usr/bin/curl", ["-fsSL", release.url, "-o", temp])
        let actual = try sh("/usr/bin/shasum", ["-a", "256", temp]).split(separator: " ").first.map(String.init)
        guard actual == release.sha256 else {
            throw CorralError("Checksum mismatch for \(tool.title) \(release.version). Corral did not install it.")
        }
        let target = toolsDir + "/" + tool.file
        try? fm.removeItem(atPath: target)
        try fm.moveItem(atPath: temp, toPath: target)
        var versions = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: toolsDir + "/versions.json"))))
            as? [String: [String: String]] ?? [:]
        versions[tool.name] = ["version": release.version, "sha256": release.sha256]
        try JSONSerialization.data(withJSONObject: versions, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: toolsDir + "/versions.json"))
    }

    /// Installs the newest release unless the installed one is as new. Returns the new version, or nil when it is up to date.
    @discardableResult
    func updateTool(_ tool: Tool) throws -> String? {
        let release = try latestRelease(tool)
        if let current = installedTool(tool)?.version, current.compare(release.version, options: .numeric) != .orderedAscending { return nil }
        try installTool(tool, release)
        return release.version
    }
}
