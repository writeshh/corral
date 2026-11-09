import AppKit

/// What `corral uninstall:herd` removes. It follows Herd's own uninstall script (Herd.app/Contents/Resources/uninstall)
/// and its docs page "Uninstalling", with two changes: files go to the Trash, not `rm -rf`, and /etc/resolver/test
/// stays when it points to Corral. Everything comes from what is on disk, so a dry run shows the real list.
struct HerdUninstall {
    var app: String?                       // Herd.app, to the Trash
    var support: String?                   // ~/Library/Application Support/Herd, to the Trash
    var supportSize = 0
    var services: (path: String, size: Int)? // Herd Pro databases and storage: needs its own yes
    var nodeVersions: [String] = []        // Node.js versions in Herd's nvm: they go with the folder
    var shellFiles: [String: String] = [:] // file -> its text without Herd's lines
    var rootFiles: [String] = []           // helper, LaunchDaemon, sudoers file: removed with one admin prompt
    var removesResolver = false            // /etc/resolver/test is Herd's own (nameserver 127.0.0.1 only)
    var resolverBackup = false             // Corral's copy of Herd's resolver file, for `migrate:herd --undo`
    var defaults = false                   // the de.beyondco.herd defaults domain
    var loginItem = false
    var valetCA = false                    // "Laravel Valet CA Self Signed CN" in the System keychain: only on request

    var isEmpty: Bool {
        app == nil && support == nil && shellFiles.isEmpty && rootFiles.isEmpty && !removesResolver && !resolverBackup && !defaults && !loginItem
    }

    /// One line for each change, in the order they happen.
    func summary(removeCA: Bool) -> [String] {
        let size = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        var out: [String] = []
        if !rootFiles.isEmpty { out.append("Stop Herd's processes and remove its system files (admin password): " + rootFiles.joined(separator: ", ")) }
        if removesResolver { out.append("Remove /etc/resolver/test (Herd's file)") }
        if resolverBackup { out.append("Remove Corral's backup of Herd's resolver file. `corral migrate:herd --undo` no longer works.") }
        if loginItem { out.append("Remove Herd from the login items") }
        for file in shellFiles.keys.sorted() { out.append("Remove Herd's lines from \((file as NSString).abbreviatingWithTildeInPath) (backup: \((file as NSString).lastPathComponent).corral-herd.bak)") }
        if defaults { out.append("Delete Herd's settings (defaults delete de.beyondco.herd)") }
        if let support { out.append("Move \((support as NSString).abbreviatingWithTildeInPath) (\(size(supportSize))) to the Trash") }
        if let services { out.append("  It holds Herd Pro service data (databases, storage) in config/services: \(size(services.size))") }
        if !nodeVersions.isEmpty {
            out.append("  It holds Herd's Node.js \(nodeVersions.joined(separator: ", ")). node and npm stop working in new terminals until you install Node another way, for example brew install node.")
        }
        if let app { out.append("Move \(app) to the Trash") }
        if valetCA && removeCA { out.append("Remove the Laravel Valet CA from the System keychain") }
        return out
    }
}

extension Corral {
    static let herdHelper = "/Library/PrivilegedHelperTools/de.beyondco.herd.helper"
    static let herdDaemon = "/Library/LaunchDaemons/de.beyondco.herd.helper.plist"
    static let valetCAName = "Laravel Valet CA Self Signed CN"

    /// root: "" on a real Mac. Tests pass a folder that stands in for /.
    static func herdUninstallPlan(home: String = NSHomeDirectory(), root: String = "") -> HerdUninstall {
        let fm = FileManager.default
        let exists = { fm.fileExists(atPath: root + $0) }
        var plan = HerdUninstall()
        if exists("/Applications/Herd.app") { plan.app = root + "/Applications/Herd.app" }
        let support = home + "/Library/Application Support/Herd"
        if fm.fileExists(atPath: support) {
            plan.support = support
            plan.supportSize = folderSize(support)
            let services = support + "/config/services"
            if let items = try? fm.contentsOfDirectory(atPath: services), !items.isEmpty { plan.services = (services, folderSize(services)) }
            plan.nodeVersions = ((try? fm.contentsOfDirectory(atPath: support + "/config/nvm/versions/node")) ?? []).filter { $0.hasPrefix("v") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        for name in [".zshrc", ".bashrc", ".bash_profile"] {
            let file = home + "/" + name
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let clean = withoutHerdLines(text, home: home)
            if clean != text { plan.shellFiles[file] = clean }
        }
        plan.rootFiles = [herdHelper, herdDaemon, "/etc/sudoers.d/herd"].filter(exists)
        plan.removesResolver = (try? String(contentsOfFile: root + "/etc/resolver/test", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "nameserver 127.0.0.1"
        plan.resolverBackup = exists(resolverBackup)
        if root.isEmpty {
            plan.defaults = (try? sh("/usr/bin/defaults", ["read", "de.beyondco.herd"])) != nil
            plan.loginItem = herdLoginItem
            plan.valetCA = (try? sh("/usr/bin/security", ["find-certificate", "-c", valetCAName, "/Library/Keychains/System.keychain"])) != nil
        }
        return plan
    }

    /// The lines that Herd adds to a shell file, from the list in Herd's uninstall script. The nvm loader line
    /// goes only when it follows Herd's NVM_DIR line: other nvm installs use the same line.
    static func withoutHerdLines(_ text: String, home: String) -> String {
        let herd = home + "/Library/Application Support/Herd"
        var out: [Substring] = [], afterNVM = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let herdLine = t.hasPrefix("# Herd injected")
                || t == "export PATH=\"\(herd)/bin/\":$PATH"
                || t.wholeMatch(of: /export HERD_PHP_\d+_INI_SCAN_DIR=".*"/) != nil
                || t == "export NVM_DIR=\"\(herd)/config/nvm\""
                || (t.contains("/Applications/Herd.app/Contents/Resources/config/shell/") && t.contains("source"))
                || (afterNVM && t.hasPrefix("[ -s \"$NVM_DIR/nvm.sh\" ]"))
            afterNVM = t == "export NVM_DIR=\"\(herd)/config/nvm\""
            if !herdLine { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// Everything that needs root, in one script, so the user sees one password prompt.
    static func herdUninstallScript(_ plan: HerdUninstall, removeCA: Bool) -> String {
        var lines = [
            "pkill -f '^/Applications/Herd.app/' || true", // Herd's dnsmasq, nginx and php-fpm can run as root
            // Herd's own script lets the helper remove itself. The rm after it covers a helper that does not.
            "if [ -x \"\(herdHelper)\" ]; then \"\(herdHelper)\" uninstall || true; fi",
            "launchctl bootout system/de.beyondco.herd.helper 2>/dev/null || true",
        ]
        if !plan.rootFiles.isEmpty { lines.append("rm -f " + plan.rootFiles.map { "\"\($0)\"" }.joined(separator: " ")) }
        if plan.removesResolver { lines.append("if [ \"$(cat /etc/resolver/test)\" = \"nameserver 127.0.0.1\" ]; then rm -f /etc/resolver/test; fi") }
        if plan.resolverBackup { lines.append("rm -f \"\(resolverBackup)\"") }
        if removeCA && plan.valetCA { lines.append("security delete-certificate -c \"\(valetCAName)\" /Library/Keychains/System.keychain || true") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs the plan. Herd quits first, like Herd's own script asks. Returns what could not be done.
    func uninstallHerd(_ plan: HerdUninstall, removeCA: Bool) throws -> [String] {
        if Self.herdIsRunning { try Self.quitHerd() }
        try runAsAdmin(Self.herdUninstallScript(plan, removeCA: removeCA))
        var problems: [String] = []
        if plan.loginItem { do { try Self.setHerdLoginItem(false) } catch { problems.append("Login item: \(error.localizedDescription)") } }
        for (file, text) in plan.shellFiles {
            do {
                let backup = file + ".corral-herd.bak"
                if !FileManager.default.fileExists(atPath: backup) { try FileManager.default.copyItem(atPath: file, toPath: backup) }
                try text.write(toFile: file, atomically: true, encoding: .utf8)
            } catch { problems.append("\(file): \(error.localizedDescription)") }
        }
        if plan.defaults { _ = try? Self.sh("/usr/bin/defaults", ["delete", "de.beyondco.herd"]) }
        for path in [plan.support, plan.app].compactMap({ $0 }) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            catch { problems.append("Could not move \(path) to the Trash: \(error.localizedDescription). Drag it to the Trash in Finder.") }
        }
        return problems
    }

    static func folderSize(_ path: String) -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let url as URL in walk { total += (try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0 }
        return total
    }
}
