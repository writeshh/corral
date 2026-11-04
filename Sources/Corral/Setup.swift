import Foundation

/// Set-up for a cloned WordPress or Laravel site, started from the panel. The steps are the same as in
/// `corral wp:setup` and `corral laravel:setup`, but the output is captured and shown only when a step fails.
extension Corral {
    static func needsWordPressSetup(_ path: String) -> Bool {
        let has = { FileManager.default.fileExists(atPath: path + "/" + $0) }
        return !has("wp-config.php") && (has("wp-content") || has("wp-load.php"))
    }

    static func needsLaravelSetup(_ path: String) -> Bool {
        let has = { FileManager.default.fileExists(atPath: path + "/" + $0) }
        return has("artisan") && (!has(".env") || !has("vendor/autoload.php"))
    }

    func setUpWordPress(_ site: Site) throws {
        let host = "\(site.name).\(config.tld)"
        try setSecure(site, true)
        for step in CLI.wpSetupSteps(name: site.name, host: host, dir: site.path) { try runStep(step, in: site.path) }
    }

    func setUpLaravel(_ site: Site) throws {
        let host = "\(site.name).\(config.tld)"
        try setSecure(site, true)
        try CLI.laravelSetup(name: site.name, host: host, dir: site.path, seed: false) { try self.runStep($0, in: site.path) }
    }

    /// Runs one command in a folder. A menu bar app has a short PATH, so Homebrew and Corral's own bin/ are added.
    func runStep(_ argv: [String], in dir: String) throws {
        let path = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        do {
            try sh("/bin/sh", ["-c", "cd \"$0\" && p=$1 && shift && exec /usr/bin/env \"PATH=$p\" \"$@\"", dir, path] + argv)
        } catch {
            // The message holds the whole output of the command. The end of it holds the cause.
            let text = error.localizedDescription
            throw CorralError(text.count > 600 ? "…" + text.suffix(600) : text)
        }
    }
}
