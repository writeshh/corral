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

    /// Reads a mysqldump file (.sql, or .sql.gz) into a database with mysqli, so no mysql client is needed.
    /// The connection comes from DB_HOST, DB_USER, DB_PASSWORD and DB_NAME in the environment. A statement ends
    /// at a line that ends with ";": mysqldump and `wp db export` write each value on one line.
    // ponytail: no DELIMITER blocks (stored procedures). Such a dump needs the mysql client.
    static let sqlImporter = #"""
    <?php
    $host = getenv('DB_HOST'); $port = 3306; $socket = null;
    if (str_contains($host, ':')) { [$host, $extra] = explode(':', $host, 2); is_numeric($extra) ? $port = (int) $extra : $socket = $extra; }
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $line = 0;
    try {
        $db = new mysqli($host, getenv('DB_USER'), getenv('DB_PASSWORD'), '', $port, $socket);
        $name = getenv('DB_NAME');
        $db->query('CREATE DATABASE IF NOT EXISTS `' . str_replace('`', '``', $name) . '`');
        $db->select_db($name);
        $db->set_charset('utf8mb4');
        $db->query('SET foreign_key_checks = 0, unique_checks = 0, autocommit = 0');
        $in = gzopen($argv[1], 'r') ?: throw new RuntimeException("Cannot read {$argv[1]}");
        $sql = ''; $count = 0;
        while (($text = gzgets($in)) !== false) {
            $line++;
            $trim = rtrim($text);
            if ($sql === '' && ($trim === '' || str_starts_with($trim, '--') || str_starts_with($trim, '#'))) continue;
            if ($sql === '' && stripos($trim, 'DELIMITER') === 0) throw new RuntimeException('DELIMITER is not supported. Import this file with the mysql client.');
            $sql .= $text;
            if (str_ends_with($trim, ';')) { $db->query($sql); $sql = ''; $count++; }
        }
        $db->commit();
        echo "Imported $count statements into $name." . PHP_EOL;
    } catch (Throwable $e) {
        fwrite(STDERR, "Import failed at line $line: " . $e->getMessage() . PHP_EOL);
        exit(1);
    }
    """#

    /// `corral wp:import` and the panel: import the dump into the database of wp-config.php, then replace the old
    /// address (from siteurl) with https://<host>. run executes a command in the site folder and returns its output.
    /// Returns a short summary.
    static func wpImport(dump: String, host: String, run: ([String]) throws -> String) throws -> String {
        func last(_ argv: [String]) throws -> String { // the value is the last line: notices come first
            try run(argv).split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let env = try ["DB_NAME", "DB_USER", "DB_PASSWORD", "DB_HOST"].map { "\($0)=\(try last(["wp", "config", "get", $0]))" }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("corral-import-\(UUID().uuidString).php")
        try sqlImporter.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let imported = try last(env + ["php", script.path, dump])

        // Plugins can print notices that hide the value, so they stay off for these commands.
        let quiet = ["--skip-plugins", "--skip-themes"]
        let old = try last(["wp", "option", "get", "siteurl"] + quiet)
        guard let oldHost = wpHost(old), oldHost != host else { return imported }
        // "//host" catches http and https. ponytail: it also matches a longer host that starts with the same name.
        let flags = ["--all-tables-with-prefix", "--skip-columns=guid", "--report-changed-only"] + quiet
        try run(["wp", "search-replace", "//" + oldHost, "//" + host] + flags)
        try run(["wp", "search-replace", "http://" + host, "https://" + host] + flags)
        return "\(imported) Replaced \(oldHost) with \(host)."
    }

    /// shop.example.com:8080 from https://shop.example.com:8080/wp. Nil for a value that is not a URL.
    static func wpHost(_ url: String) -> String? {
        guard let m = url.wholeMatch(of: /https?:\/\/([^\/\s]+).*/) else { return nil }
        return String(m.1)
    }

    func setUpWordPress(_ site: Site) throws {
        let host = "\(site.name).\(config.tld)"
        try setSecure(site, true)
        for step in CLI.wpSetupSteps(name: site.name, host: host, dir: site.path, wp: config.wordpress) { try runStep(step, in: site.path) }
    }

    func setUpLaravel(_ site: Site) throws {
        let host = "\(site.name).\(config.tld)"
        try setSecure(site, true)
        try CLI.laravelSetup(name: site.name, host: host, dir: site.path, seed: false) { try self.runStep($0, in: site.path) }
    }

    /// Loads a SQL dump into the site's WordPress database, then moves its URLs to the site's own name.
    func importWordPressDump(_ site: Site, dump: String) throws -> String {
        try Self.wpImport(dump: dump, host: "\(site.name).\(config.tld)") { try self.runStep($0, in: site.path) }
    }

    /// Runs one command in a folder and returns its output. A menu bar app has a short PATH, so Homebrew and Corral's own bin/ are added.
    @discardableResult
    func runStep(_ argv: [String], in dir: String) throws -> String {
        let path = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        do {
            return try sh("/bin/sh", ["-c", "cd \"$0\" && p=$1 && shift && exec /usr/bin/env \"PATH=$p\" \"$@\"", dir, path] + argv)
        } catch {
            // The message holds the whole output of the command. The end of it holds the cause.
            let text = error.localizedDescription
            throw CorralError(text.count > 600 ? "…" + text.suffix(600) : text)
        }
    }
}
