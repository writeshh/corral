import AppKit

struct Config: Codable, Equatable {
    var tld = "test"                     // main TLD: URLs and certificate file names use it
    var aliases: [String] = []           // extra TLDs, for example "internal": every site also answers <site>.internal
    var php: String?                     // global PHP version; nil = newest installed
    var parked: [String] = []
    var links: [String: String] = [:]    // site name -> directory
    var secured: Set<String> = []
    var isolated: [String: String] = [:] // site name -> PHP version
    var proxies: [String: String] = [:]  // site name -> upstream URL
    var fpm: [String: FpmPool] = [:]     // PHP version -> pool settings, when not the defaults
    var dumps = false                    // send dump() and dd() output to the Insights window
    var mail = false                     // catch mail on 127.0.0.1:2525 while the app runs

    init() {}

    // Missing keys keep their defaults, so a config.json from an older Corral still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        tld = try c.decodeIfPresent(String.self, forKey: .tld) ?? d.tld
        // Before aliases existed, every site also answered .test. Keep that for old configs.
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? (tld == Corral.sharedTLD ? [] : [Corral.sharedTLD])
        php = try c.decodeIfPresent(String.self, forKey: .php)
        parked = try c.decodeIfPresent([String].self, forKey: .parked) ?? d.parked
        links = try c.decodeIfPresent([String: String].self, forKey: .links) ?? d.links
        secured = try c.decodeIfPresent(Set<String>.self, forKey: .secured) ?? d.secured
        isolated = try c.decodeIfPresent([String: String].self, forKey: .isolated) ?? d.isolated
        proxies = try c.decodeIfPresent([String: String].self, forKey: .proxies) ?? d.proxies
        fpm = try c.decodeIfPresent([String: FpmPool].self, forKey: .fpm) ?? d.fpm
        dumps = try c.decodeIfPresent(Bool.self, forKey: .dumps) ?? d.dumps
        mail = try c.decodeIfPresent(Bool.self, forKey: .mail) ?? d.mail
    }
}

/// PHP-FPM process settings for one PHP version.
struct FpmPool: Codable, Equatable, Sendable {
    var pm = "dynamic"                    // dynamic, ondemand or static
    var maxChildren = 5
    var requestTerminateTimeout = 0       // seconds, 0 = no limit
    var slowlogTimeout = 0                // seconds, 0 = no slow log
}

/// Optional `.corral.json` in a site folder.
struct SiteOverrides: Codable, Equatable {
    var root: String?   // document root, relative to the site folder
    var nginx: String?  // extra directives inside the site's server block
    var domains: [String]? // extra host names, for example ["shop.local"]
    var php: [String: String]? // php.ini values for this site only, for example ["memory_limit": "2048M"]
}

struct Site: Identifiable, Equatable {
    let name: String
    let path: String
    var overrides = SiteOverrides()
    var overridesError: String?
    var proxy: URL?
    var id: String { name }

    /// A proxy site: nginx forwards requests to `proxy`, for example a Next.js dev server.
    init(name: String, proxy: URL) {
        self.name = name
        self.path = proxy.absoluteString
        self.proxy = proxy
    }

    init(name: String, path: String) {
        self.name = name
        self.path = path
        if let data = FileManager.default.contents(atPath: path + "/.corral.json") {
            do { overrides = try JSONDecoder().decode(SiteOverrides.self, from: data) } catch { overridesError = "\(error)" }
        }
    }

    /// `.corral.json` root, else `public/` (Laravel, Symfony), else `web/` (Craft, Drupal, Bedrock), else the folder.
    var docroot: String {
        if let root = overrides.root { return URL(fileURLWithPath: root, relativeTo: URL(fileURLWithPath: path + "/")).standardizedFileURL.path }
        for sub in ["public", "web"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(path)/\(sub)", isDirectory: &isDir), isDir.boolValue { return "\(path)/\(sub)" }
        }
        return path
    }

    var isWordPress: Bool {
        proxy == nil && ["wp-load.php", "wp-config.php"].contains { FileManager.default.fileExists(atPath: "\(docroot)/\($0)") }
    }
}

struct CorralError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Mirrors Herd's layout: unprivileged nginx + dnsmasq + one php-fpm pool per PHP version.
/// Root is only used once by `install()` (resolver file + loopback alias + pf redirect).
// @unchecked: the menu bar app calls Corral only from Model's serial work queue. The CLI is single-threaded.
final class Corral: @unchecked Sendable {
    static let loopback = "127.0.0.2", httpPort = 8180, httpsPort = 8543, dnsPort = 53535
    static let dumpPort = 9912 // Symfony VarDumper's server port, the default of `php artisan dump-server`
    static let daemonLabel = "dev.corral.network"

    let home: String
    let brew: String
    var config = Config()
    private(set) var loadError: String?

    init(home: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.home = home ?? env["CORRAL_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Corral"
        self.brew = env["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        let data = try? Data(contentsOf: URL(fileURLWithPath: self.home + "/config.json"))
        if let data {
            do { config = try JSONDecoder().decode(Config.self, from: data) } catch { loadError = "\(error)" }
        } else { // first run: park ~/Corral, like Herd parks ~/Herd
            config.parked = [NSHomeDirectory() + "/Corral"]
            if home == nil { try? FileManager.default.createDirectory(atPath: config.parked[0], withIntermediateDirectories: true) }
        }
    }

    var conf: String { home + "/conf" }
    var run: String { home + "/run" }
    var logs: String { home + "/logs" }
    var certs: String { home + "/certs" }

    func save() throws {
        // Never replace a config.json that failed to load: the user's settings would be lost.
        if let loadError { throw CorralError("\(home)/config.json is not valid. Repair or delete it. \(loadError)") }
        try mkdirs(home)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: URL(fileURLWithPath: home + "/config.json"))
    }

    // MARK: Sites

    /// Folder name -> host label. Keeps dots like Herd and Valet, so "crm.pigment" serves crm.pigment.<tld>.
    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    func sites() -> [Site] {
        let fm = FileManager.default
        var byName: [String: Site] = [:]
        for dir in config.parked {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !entry.hasPrefix(".") {
                var isDir: ObjCBool = false
                let path = dir + "/" + entry
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let name = Self.slug(entry)
                if !name.isEmpty { byName[name] = Site(name: name, path: path) }
            }
        }
        for (name, path) in config.links { byName[name] = Site(name: name, path: path) } // links win over parked
        for (name, url) in config.proxies { if let url = URL(string: url) { byName[name] = Site(name: name, proxy: url) } }
        return byName.values.sorted { $0.name < $1.name }
    }

    func site(named name: String?) throws -> Site {
        let cwd = FileManager.default.currentDirectoryPath
        let all = sites()
        let match = if let name { all.first { $0.name == Self.slug(name) } } else { all.first { $0.path == cwd } }
        if let match { return match }
        throw CorralError("No site \(name.map { "'\($0)'" } ?? "for \(cwd)"). Park its parent or run `corral link`.")
    }

    func host(_ site: Site) -> String { "\(site.name).\(config.tld)" }

    /// The TLD that Herd also uses. `corral takeover` and `handback` move it between the two.
    static let sharedTLD = "test"
    var tlds: [String] { ([config.tld] + config.aliases).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    /// Main name first: certificate files use it.
    func hostnames(_ site: Site) -> [String] {
        (tlds.map { "\(site.name).\($0)" } + (site.overrides.domains ?? []).map { $0.lowercased() })
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Every name that dnsmasq answers: the TLDs plus the extra domains of each site.
    func dnsNames(_ sites: [Site]) -> [String] {
        tlds + Set(sites.flatMap { $0.overrides.domains ?? [] }.map { $0.lowercased() }).subtracting(tlds).sorted()
    }

    /// The TLDs that need a file in /etc/resolver. .test needs one only when it is the main TLD:
    /// as an alias, `corral takeover` decides who gets it.
    func resolverTLDs(_ sites: [Site]) -> [String] {
        let all = tlds + dnsNames(sites).compactMap { $0.split(separator: ".").last.map(String.init) }
        return Set(all).filter { $0 != Self.sharedTLD || config.tld == Self.sharedTLD }.sorted()
    }

    /// TLDs in use that do not resolve to Corral yet. `corral install` fixes them.
    func missingResolvers() -> [String] {
        resolverTLDs(sites()).filter { !Self.resolverIsCorral("/etc/resolver/" + $0) }
    }

    func url(_ site: Site) -> URL {
        URL(string: (config.secured.contains(site.name) ? "https://" : "http://") + host(site))!
    }

    // MARK: PHP

    var phpDir: String { home + "/php" }
    var binDir: String { home + "/bin" }

    // ponytail: keep in step with the matrix in .github/workflows/php.yml.
    static let phpChoices = ["8.5", "8.4", "8.3", "8.2", "8.1"]

    /// version ("8.5") -> php-fpm path. Only Corral's own builds count: Homebrew, Herd and other PHP installs are
    /// ignored, so every site runs a build with the same extensions and php.ini.
    func phpVersions() -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for v in (try? fm.contentsOfDirectory(atPath: phpDir)) ?? [] where fm.isExecutableFile(atPath: "\(phpDir)/\(v)/php-fpm") {
            out[v] = "\(phpDir)/\(v)/php-fpm"
        }
        return out
    }

    func cliPath(_ fpm: String) -> String { (fpm as NSString).deletingLastPathComponent + "/php" }

    /// Corral's builds keep php.ini next to the binaries.
    func iniArgs(_ fpm: String) -> [String] { ["-c", iniPath("", fpm)] }

    /// The php.ini file that a version reads.
    func iniPath(_ version: String, _ fpm: String) -> String { (fpm as NSString).deletingLastPathComponent + "/php.ini" }

    /// The full version of an installed build, for example "8.4.27". Installs write it to VERSION.
    /// An older install has no such file, so PHP reports its version once and the file keeps it.
    func phpFullVersion(_ minor: String) -> String? {
        let file = "\(phpDir)/\(minor)/VERSION"
        if let v = try? String(contentsOfFile: file, encoding: .utf8) { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let v = try? sh("\(phpDir)/\(minor)/php", ["-n", "-r", "echo PHP_VERSION;"]), v.hasPrefix(minor + ".") else { return nil }
        try? v.write(toFile: file, atomically: true, encoding: .utf8)
        return v
    }

    // Same values as Herd's php.ini, so sites behave the same after a move. output_buffering keeps
    // early notices (for example PHP 8.4 deprecations) from breaking redirects and cookies.
    static let defaultPhpIni = """
    memory_limit = 1024M
    upload_max_filesize = 512M
    post_max_size = 512M
    max_execution_time = 600
    output_buffering = 4096
    date.timezone = UTC
    ; Static builds have no CA bundle. Use the macOS bundle.
    curl.cainfo = /etc/ssl/cert.pem
    openssl.cafile = /etc/ssl/cert.pem

    """

    /// Corral's own PHP builds: the "php-builds" release that .github/workflows/php.yml publishes.
    /// CORRAL_PHP_SOURCE points elsewhere, for example a file:// folder with a local build.
    var phpSource = ProcessInfo.processInfo.environment["CORRAL_PHP_SOURCE"]
        ?? "https://github.com/writeshh/corral/releases/download/php-builds"

    /// Downloads the newest build for a minor version, checks its SHA-256 from manifest.json, then installs it.
    /// minor version -> {version, file, sha256} from the build list.
    func phpManifest() throws -> [String: [String: String]] {
        // The tarball names carry the version, so a cached copy is always right. manifest.json changes in place, and
        // GitHub's release CDN serves an old copy for a while after an update. A query string skips that cache.
        let fresh = phpSource.hasPrefix("http") ? "?t=\(Int(Date().timeIntervalSince1970))" : ""
        guard let text = try? sh("/usr/bin/curl", ["-fsSL", "-H", "Cache-Control: no-cache", phpSource + "/manifest.json" + fresh]) else {
            throw CorralError("Corral could not read the PHP build list at \(phpSource)/manifest.json.")
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: [String: String]] ?? [:]
    }

    func installPHP(_ minor: String) throws {
        let fm = FileManager.default
        #if !arch(arm64)
        throw CorralError("Corral's PHP builds are for Apple silicon only.")
        #endif
        let manifest = try phpManifest()
        guard let entry = manifest[minor], let file = entry["file"], let sha256 = entry["sha256"], !file.contains("/") else {
            let available = Self.sortVersions(manifest.keys).joined(separator: ", ")
            throw CorralError("No Corral PHP build for \(minor). Available: \(available.isEmpty ? "none" : available).")
        }

        let dir = "\(phpDir)/\(minor)", tmp = dir + ".download", tarball = tmp + "/php.tar.gz"
        try? fm.removeItem(atPath: tmp)
        try mkdirs(tmp)
        try sh("/usr/bin/curl", ["-fsSL", "\(phpSource)/\(file)", "-o", tarball])
        let actual = try sh("/usr/bin/shasum", ["-a", "256", tarball]).split(separator: " ").first.map(String.init)
        guard actual == sha256 else {
            try? fm.removeItem(atPath: tmp)
            throw CorralError("Checksum mismatch for \(file). Corral did not install it.")
        }
        try sh("/usr/bin/tar", ["xzf", tarball, "-C", tmp])
        try fm.removeItem(atPath: tarball)
        try entry["version"]?.write(toFile: tmp + "/VERSION", atomically: true, encoding: .utf8)
        for bin in ["php", "php-fpm"] { try sh("/usr/bin/codesign", ["--force", "--sign", "-", "\(tmp)/\(bin)"]) }
        if fm.fileExists(atPath: dir + "/php.ini") {
            try fm.moveItem(atPath: dir + "/php.ini", toPath: tmp + "/php.ini") // keep the user's edits on update
        } else {
            try Self.defaultPhpIni.write(toFile: tmp + "/php.ini", atomically: true, encoding: .utf8)
        }
        stopPHP(minor)
        try? fm.removeItem(atPath: dir)
        try fm.moveItem(atPath: tmp, toPath: dir)
        try apply()
    }

    func uninstallPHP(_ minor: String) throws {
        guard FileManager.default.fileExists(atPath: "\(phpDir)/\(minor)") else { throw CorralError("PHP \(minor) is not installed by Corral.") }
        stopPHP(minor)
        try FileManager.default.removeItem(atPath: "\(phpDir)/\(minor)")
        if config.php == minor { config.php = nil }
        try apply()
    }

    func stopPHP(_ version: String) {
        let pidFile = "\(run)/php\(version)-fpm.pid"
        if let pid = readPid(pidFile) { kill(pid, SIGTERM) }
        for _ in 0..<30 where alive(pidFile) { usleep(100_000) }
    }

    static func sortVersions(_ v: some Sequence<String>) -> [String] {
        v.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    func globalPHP(_ installed: [String: String]) -> String? {
        config.php.flatMap { installed[$0] != nil ? $0 : nil } ?? Self.sortVersions(installed.keys).last
    }

    func php(for site: Site, _ installed: [String: String]) -> String? {
        config.isolated[site.name].flatMap { installed[$0] != nil ? $0 : nil } ?? globalPHP(installed)
    }

    func sock(_ version: String) -> String { "\(run)/php\(version).sock" }

    /// A site with its own php.ini values gets its own FPM pool. PHP_VALUE from nginx would stay
    /// set in the worker and leak into the next request of another site.
    /// The socket name is a hash of the site name: macOS limits socket paths to 104 bytes.
    func sock(_ version: String, for site: Site) -> String {
        guard site.overrides.php?.isEmpty == false else { return sock(version) }
        let hash = site.name.utf8.reduce(UInt32(5381)) { $0 &* 33 &+ UInt32($1) } // djb2: stable between runs
        return "\(run)/php\(version)-\(String(hash, radix: 16)).sock"
    }

    // MARK: PHP settings

    /// The value that PHP uses: the last line that sets the key.
    static func iniValue(_ ini: String, _ key: String) -> String? {
        for line in ini.components(separatedBy: "\n").reversed() {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Changes the line that PHP uses for the key, or adds one. Comments and other lines stay as they are.
    static func setIni(_ ini: String, _ key: String, _ value: String) -> String {
        var lines = ini.components(separatedBy: "\n")
        let line = "\(key) = \(value)"
        if let i = lines.lastIndex(where: { $0.contains("=") && $0.split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces) == key }) {
            lines[i] = line
        } else if lines.last == "" {
            lines.insert(line, at: lines.count - 1)
        } else {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// PHP accepts a bad php.ini with exit code 0 and prints warnings. Any output is an error.
    func checkIni(_ ini: String, cli: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-\(UUID().uuidString).ini").path
        try ini.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let out = try sh(cli, ["-c", tmp, "-d", "display_startup_errors=1", "-d", "error_reporting=-1", "-r", ""])
            .replacingOccurrences(of: tmp, with: "php.ini").trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { throw CorralError("php.ini is not valid. Nothing was changed. \(out)") }
    }

    /// Writes php.ini values and the FPM pool of one version, after PHP accepts both. Then reloads php-fpm.
    func savePHPSettings(_ version: String, ini values: [String: String], pool: FpmPool) throws {
        guard let fpm = phpVersions()[version] else { throw CorralError("PHP \(version) is not installed.") }
        let path = iniPath(version, fpm)
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let ini = values.sorted { $0.key < $1.key }.reduce(old) { Self.iniValue($0, $1.key) == $1.value ? $0 : Self.setIni($0, $1.key, $1.value) }
        try checkIni(ini, cli: cliPath(fpm))

        let previous = config.fpm[version]
        config.fpm[version] = pool == FpmPool() ? nil : pool
        let tmp = "\(conf)/php\(version)-fpm.test.conf"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            for d in [conf, logs] { try mkdirs(d) } // php-fpm -t opens the error log
            let installed = phpVersions()
            try fpmConf(version, sites: sites().filter { php(for: $0, installed) == version }).write(toFile: tmp, atomically: true, encoding: .utf8)
            try sh(fpm, ["-t", "--fpm-config", tmp] + iniArgs(fpm))
        } catch {
            config.fpm[version] = previous
            throw CorralError("The PHP-FPM settings are not valid. Nothing was changed. \(error.localizedDescription)")
        }

        if ini != old { try ini.write(toFile: path, atomically: true, encoding: .utf8) }
        try save()
        if !(try writeConfigs()).contains(version) { reloadPHP(version) } // a changed pool reloads already
    }

    /// Graceful reload: php-fpm finishes the running requests, then reads php.ini and its pool again.
    func reloadPHP(_ version: String) {
        let pidFile = "\(run)/php\(version)-fpm.pid"
        if alive(pidFile), let pid = readPid(pidFile) { kill(pid, SIGUSR2) }
    }

    // MARK: Config rendering

    func nginxConf(sites: [Site], installed: [String: String]) -> String {
        var out = """
        worker_processes 1;
        pid "\(run)/nginx.pid";
        error_log "\(logs)/nginx-error.log";
        events { worker_connections 1024; }
        http {
            types {
                text/html html htm; text/css css; text/plain txt; application/javascript js mjs;
                application/json json map; application/wasm wasm; application/pdf pdf; image/svg+xml svg;
                image/png png; image/jpeg jpg jpeg; image/gif gif; image/webp webp; image/avif avif;
                image/x-icon ico; font/woff woff; font/woff2 woff2;
            }
            default_type application/octet-stream;
            access_log off;
            sendfile on;
            client_max_body_size 512M;
            client_body_temp_path "\(run)/tmp/body";
            proxy_temp_path "\(run)/tmp/proxy";
            fastcgi_temp_path "\(run)/tmp/fastcgi";

            map $http_upgrade $connection_upgrade { default upgrade; "" close; }

            server { listen 127.0.0.1:\(Self.httpPort) default_server; return 404 "No Corral site here.\\n"; }

        """
        for site in sites {
            let names = hostnames(site).map { "\($0) *.\($0)" }.joined(separator: " ")
            let sock = php(for: site, installed).map { self.sock($0, for: site) } ?? "\(run)/no-php.sock"
            let body = { (https: Bool) in site.proxy.map(self.proxyBody) ?? self.siteBody(site, sock: sock, https: https) }
            if config.secured.contains(site.name) {
                out += """
                    server { listen 127.0.0.1:\(Self.httpPort); server_name \(names); return 301 https://$host$request_uri; }
                    server {
                        listen 127.0.0.1:\(Self.httpsPort) ssl;
                        http2 on;
                        server_name \(names);
                        ssl_certificate "\(certs)/\(host(site)).crt";
                        ssl_certificate_key "\(certs)/\(host(site)).key";
                \(body(true))
                    }

                """
            } else {
                out += """
                    server {
                        listen 127.0.0.1:\(Self.httpPort);
                        server_name \(names);
                \(body(false))
                    }

                """
            }
        }
        return out + "}\n"
    }

    // Dev servers (Next.js, Vite, portless, …). `.localhost` names may not resolve outside a browser,
    // so nginx connects to 127.0.0.1 and keeps the name in the Host header and TLS SNI for name-based routers.
    func proxyBody(_ url: URL) -> String {
        let host = url.host ?? "127.0.0.1"
        let port = url.port.map { ":\($0)" } ?? ""
        let target = host == "localhost" || host.hasSuffix(".localhost") ? "127.0.0.1" : host
        let tls = url.scheme == "https" ? "proxy_ssl_server_name on;\n            proxy_ssl_name \(host);" : ""
        return """
                location / {
                    proxy_pass \(url.scheme ?? "http")://\(target)\(port);
                    proxy_http_version 1.1;
                    proxy_set_header Host "\(host)\(port)";
                    proxy_set_header Upgrade $http_upgrade;
                    proxy_set_header Connection $connection_upgrade;
                    proxy_set_header X-Forwarded-Host $host;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_buffering off;
                    proxy_read_timeout 1h;
                    \(tls)
                }
        """
    }

    // WordPress multisite in subdirectories: map /site/wp-admin/... and /site/*.php back to the core files.
    // Harmless for a single-site install: the rules only apply to paths that do not exist.
    static let wordPressRules = """
            if (!-e $request_filename) {
                rewrite /wp-admin$ $scheme://$host$uri/ permanent;
                rewrite ^(/[^/]+)?(/wp-.*) $2 last;
                rewrite ^(/[^/]+)?(/.*\\.php) $2 last;
            }
    """

    // Front-controller routing (Laravel, Symfony, Statamic, …) plus per-framework rules.
    // Herd instead routes everything through Valet's server.php + PHP drivers.
    private func siteBody(_ site: Site, sock: String, https: Bool) -> String {
        """
                root "\(site.docroot)";
                index index.php index.html;
                charset utf-8;
        \(site.isWordPress ? Self.wordPressRules : "")
                \(site.overrides.nginx ?? "")
                location / { try_files $uri $uri/ /index.php?$query_string; }
                location ~ /\\.(?!well-known) { deny all; }
                location ~ \\.php$ {
                    try_files $uri =404;
                    fastcgi_pass "unix:\(sock)";
                    fastcgi_index index.php;
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    fastcgi_param DOCUMENT_ROOT $document_root;
                    fastcgi_param QUERY_STRING $query_string;
                    fastcgi_param REQUEST_METHOD $request_method;
                    fastcgi_param CONTENT_TYPE $content_type;
                    fastcgi_param CONTENT_LENGTH $content_length;
                    fastcgi_param SCRIPT_NAME $fastcgi_script_name;
                    fastcgi_param REQUEST_URI $request_uri;
                    fastcgi_param DOCUMENT_URI $document_uri;
                    fastcgi_param SERVER_PROTOCOL $server_protocol;
                    fastcgi_param GATEWAY_INTERFACE CGI/1.1;
                    fastcgi_param SERVER_SOFTWARE nginx;
                    fastcgi_param REMOTE_ADDR $remote_addr;
                    fastcgi_param REMOTE_PORT $remote_port;
                    fastcgi_param SERVER_ADDR $server_addr;
                    fastcgi_param SERVER_NAME $host;
                    fastcgi_param SERVER_PORT \(https ? 443 : 80);
                    \(https ? "fastcgi_param HTTPS on;" : "")
                    fastcgi_param REDIRECT_STATUS 200;
                    \(config.dumps ? "fastcgi_param VAR_DUMPER_FORMAT server;\n            fastcgi_param VAR_DUMPER_SERVER 127.0.0.1:\(Self.dumpPort);" : "")
                    fastcgi_param HTTP_PROXY "";
                    fastcgi_buffers 16 64k;
                    fastcgi_buffer_size 64k;
                }
        """
    }

    /// The socket for `DB_HOST=localhost`. PHP looks for /tmp/mysql.sock, but DBngin and Herd create
    /// /tmp/mysql_3306.sock or /tmp/mysql-3306.sock. nil when PHP's default already works or no MySQL runs.
    /// ponytail: picks one server (3306 first) when several run. Add a config key if that is not enough.
    static func mysqlSocket(in dir: String = "/tmp") -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/mysql.sock") { return nil }
        let socks = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("mysql") && !$0.hasPrefix("mysqlx") && $0.hasSuffix(".sock") }
            .sorted { ($0.contains("3306") ? 0 : 1, $0) < ($1.contains("3306") ? 0 : 1, $1) }
        return socks.first.map { dir + "/" + $0 }
    }

    /// php.ini values that Corral sets for every PHP version, in FPM and in the bin/ shims.
    func phpOverrides() -> [(String, String)] {
        Self.mysqlSocket().map { [("mysqli.default_socket", $0), ("pdo_mysql.default_socket", $0)] } ?? []
    }

    /// One pool for the version, plus one small pool for each of its sites with own php.ini values.
    func fpmConf(_ version: String, sites: [Site] = []) -> String {
        let values = { (extra: [String: String]) in
            (self.phpOverrides() + extra.sorted { $0.key < $1.key }).map { "php_value[\($0.0)] = \"\($0.1)\"\n" }.joined()
        }
        let pool = config.fpm[version] ?? FpmPool()
        let pm = switch pool.pm {
        case "static": ""
        case "ondemand": "pm.process_idle_timeout = 10s"
        default: "pm.start_servers = \(min(2, pool.maxChildren))\npm.min_spare_servers = 1\npm.max_spare_servers = \(min(3, pool.maxChildren))"
        }
        let limits = (pool.requestTerminateTimeout > 0 ? "request_terminate_timeout = \(pool.requestTerminateTimeout)s\n" : "")
            + (pool.slowlogTimeout > 0 ? "request_slowlog_timeout = \(pool.slowlogTimeout)s\nslowlog = \"\(logs)/php\(version)-slow.log\"\n" : "")
        var out = """
        [global]
        pid = "\(run)/php\(version)-fpm.pid"
        error_log = "\(logs)/php\(version)-fpm.log"
        daemonize = yes

        [corral]
        listen = "\(sock(version))"
        listen.mode = 0600
        pm = \(pool.pm)
        pm.max_children = \(pool.maxChildren)
        \(pm)
        catch_workers_output = yes
        \(limits)\(values([:]))
        """
        for site in sites where site.overrides.php?.isEmpty == false {
            out += """

            [site-\(site.name)]
            listen = "\(sock(version, for: site))"
            listen.mode = 0600
            pm = ondemand
            pm.max_children = \(pool.maxChildren)
            pm.process_idle_timeout = 10s
            catch_workers_output = yes
            \(limits)\(values(site.overrides.php ?? [:]))
            """
        }
        return out
    }

    /// Returns the PHP versions whose FPM configuration changed. A running php-fpm of those reloads.
    @discardableResult
    func writeConfigs() throws -> Set<String> {
        for d in [conf, logs, certs, run + "/tmp"] { try mkdirs(d) }
        let installed = phpVersions()
        let sites = sites()
        if let bad = sites.first(where: { $0.overridesError != nil }) {
            throw CorralError("Invalid \(bad.path)/.corral.json: \(bad.overridesError!)")
        }
        try nginxConf(sites: sites, installed: installed).write(toFile: conf + "/nginx.conf", atomically: true, encoding: .utf8)
        var changed = Set<String>()
        for v in installed.keys {
            let file = "\(conf)/php\(v)-fpm.conf", text = fpmConf(v, sites: sites.filter { php(for: $0, installed) == v })
            guard (try? String(contentsOfFile: file, encoding: .utf8)) != text else { continue }
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            reloadPHP(v)
            changed.insert(v)
        }
        try writeShims(installed)
        return changed
    }

    /// bin/corral, bin/php (global version) and bin/php84 etc. Add bin/ to PATH to use them.
    func writeShims(_ installed: [String: String]) throws {
        try? FileManager.default.removeItem(atPath: binDir)
        try mkdirs(binDir)
        if let exe = Bundle.main.executablePath {
            try FileManager.default.createSymbolicLink(atPath: binDir + "/corral", withDestinationPath: exe)
        }
        let global = globalPHP(installed)
        for (v, fpm) in installed {
            let ini = iniArgs(fpm) + phpOverrides().flatMap { ["-d", "\($0.0)=\($0.1)"] }
            let args = ([cliPath(fpm)] + ini).map { "\"\($0)\"" }.joined(separator: " ")
            for name in ["php" + v.replacingOccurrences(of: ".", with: "")] + (v == global ? ["php"] : []) {
                let path = "\(binDir)/\(name)"
                try "#!/bin/sh\nexec \(args) \"$@\"\n".write(toFile: path, atomically: true, encoding: .utf8)
                chmod(path, 0o755)
            }
        }
    }

    // MARK: Processes

    /// Order: CORRAL_<NAME> override, the copy inside Corral.app, then Homebrew.
    func tool(_ name: String) throws -> String {
        if let p = ProcessInfo.processInfo.environment["CORRAL_\(name.uppercased())"] { return p }
        if let bundled = Bundle.main.resourcePath.map({ "\($0)/bin/\(name)" }),
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for dir in ["bin", "sbin"] where FileManager.default.isExecutableFile(atPath: "\(brew)/\(dir)/\(name)") {
            return "\(brew)/\(dir)/\(name)"
        }
        throw CorralError("\(name) not found. Run Corral from Corral.app (build it with ./bundle.sh), or run: brew install \(name)")
    }

    private var nginxArgs: [String] { ["-p", home + "/", "-c", conf + "/nginx.conf", "-e", logs + "/nginx-error.log"] }

    /// Versions that need a running FPM pool: the global one plus every isolated one that's installed.
    func neededPHP(_ installed: [String: String]) -> [String] {
        Self.sortVersions(Set(sites().compactMap { php(for: $0, installed) } + [globalPHP(installed)].compactMap { $0 }))
    }

    func status() -> [(String, Bool)] {
        [("nginx", alive(run + "/nginx.pid")), ("dnsmasq", alive(run + "/dnsmasq.pid"))]
            + neededPHP(phpVersions()).map { ("php \($0)", alive("\(run)/php\($0)-fpm.pid")) }
    }

    var isRunning: Bool { alive(run + "/nginx.pid") }

    /// `start` creates this file and `stop` removes it. The app starts the services again
    /// after a login or a crash only while the file exists.
    var wantsRunning: Bool { FileManager.default.fileExists(atPath: run + "/autostart") }

    /// Idempotent: writes configs, starts whatever is down, reloads nginx if it's already up.
    func start() throws {
        try writeConfigs()
        try renewCertificates()
        let installed = phpVersions()
        if installed.isEmpty { throw CorralError("No PHP found. Install it with: corral php:install \(Self.phpChoices[0])") }
        for v in neededPHP(installed) where !alive("\(run)/php\(v)-fpm.pid") {
            stopOrphanWorkers(v)
            try sh(installed[v]!, ["--fpm-config", "\(conf)/php\(v)-fpm.conf"] + iniArgs(installed[v]!))
        }
        // dnsmasq reads its names only at start. Restart it when a TLD or a site domain changes.
        let dns = dnsmasqConf(sites()), dnsFile = conf + "/dnsmasq.conf"
        if (try? String(contentsOfFile: dnsFile, encoding: .utf8)) != dns {
            try dns.write(toFile: dnsFile, atomically: true, encoding: .utf8)
            if let pid = readPid(run + "/dnsmasq.pid"), alive(run + "/dnsmasq.pid") {
                kill(pid, SIGTERM)
                for _ in 0..<30 where alive(run + "/dnsmasq.pid") { usleep(100_000) }
            }
        }
        if !alive(run + "/dnsmasq.pid") { try sh(tool("dnsmasq"), ["--conf-file=" + dnsFile]) }
        let nginx = try tool("nginx")
        try sh(nginx, nginxArgs + ["-t", "-q"])
        if isRunning {
            try sh(nginx, nginxArgs + ["-s", "reload"])
            usleep(250_000) // ponytail: reload is async (<100ms observed); poll worker PIDs if this ever races
        } else {
            try sh(nginx, nginxArgs)
        }
        FileManager.default.createFile(atPath: run + "/autostart", contents: nil)
    }

    /// Workers of a php-fpm master that died keep its sockets open. A new php-fpm then fails with
    /// "Another FPM instance seems to already listen". Stop the processes that hold the sockets.
    func stopOrphanWorkers(_ version: String) {
        let socks = ((try? FileManager.default.contentsOfDirectory(atPath: run)) ?? [])
            .filter { $0.hasPrefix("php\(version)") && $0.hasSuffix(".sock") }
        for sock in socks {
            for pid in ((try? sh("/usr/sbin/lsof", ["-t", "\(run)/\(sock)"])) ?? "").split(separator: "\n").compactMap({ pid_t($0) }) {
                kill(pid, SIGTERM)
            }
        }
        if !socks.isEmpty { usleep(200_000) }
    }

    func dnsmasqConf(_ sites: [Site]) -> String {
        """
        port=\(Self.dnsPort)
        listen-address=127.0.0.1
        bind-interfaces
        no-resolv
        no-hosts
        address=/\(dnsNames(sites).joined(separator: "/"))/\(Self.loopback)
        pid-file=\(run)/dnsmasq.pid

        """
    }

    func stop() {
        try? FileManager.default.removeItem(atPath: run + "/autostart")
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: run)) ?? []).filter { $0.hasSuffix(".pid") }
        for f in pids { if let pid = readPid(run + "/" + f) { kill(pid, SIGTERM) } }
        for _ in 0..<30 where pids.contains(where: { alive(run + "/" + $0) }) { usleep(100_000) }
    }

    /// Re-render and reload if running; just re-render otherwise.
    func apply() throws {
        try save()
        if isRunning { try start() } else { try writeConfigs() }
    }

    // MARK: TLS (same approach as Valet's Site.php: local CA + per-site leaf, trusted in the login keychain)

    var caPem: String { certs + "/CorralCA.pem" }

    @discardableResult
    func ensureCA() throws -> Bool {
        if FileManager.default.fileExists(atPath: caPem) { return false }
        try mkdirs(certs)
        let cfg = certs + "/ca.cnf"
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Corral Local CA
        O = Corral
        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """.write(toFile: cfg, atomically: true, encoding: .utf8)
        try sh("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", cfg,
                                    "-extensions", "v3_ca", "-keyout", certs + "/CorralCA.key", "-out", caPem])
        chmod(certs + "/CorralCA.key", 0o600)
        return true
    }

    func trustCA() throws {
        try sh("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-k",
                                     NSHomeDirectory() + "/Library/Keychains/login.keychain-db", caPem])
    }

    /// One certificate for all of a site's names. Files use the first name.
    func makeCert(_ hosts: [String], days: Int = 397) throws {
        let host = hosts[0], base = "\(certs)/\(host)"
        try """
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(Self.sanList(hosts))
        """.write(toFile: base + ".ext", atomically: true, encoding: .utf8)
        try sh("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(host)",
                                    "-keyout", base + ".key", "-out", base + ".csr"])
        // 397 days: Apple rejects longer-lived leaf certificates (Valet's Site.php has the same cap).
        try sh("/usr/bin/openssl", ["x509", "-req", "-sha256", "-days", "\(days)", "-in", base + ".csr",
                                    "-CA", caPem, "-CAkey", certs + "/CorralCA.key",
                                    "-set_serial", "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16),
                                    "-extfile", base + ".ext", "-out", base + ".crt"])
    }

    /// Certificate file of a secured site. Files use the first name (`<site>.<tld>`).
    func certPath(_ site: Site) -> String { "\(certs)/\(host(site)).crt" }

    /// The expiry date of a PEM certificate. Read in-process: one openssl call per site made `start` seconds slower.
    func certExpiry(_ path: String) -> Date? {
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let parts = pem.components(separatedBy: "-----")
        guard parts.count > 2,
              let der = Data(base64Encoded: parts[2], options: .ignoreUnknownCharacters),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let field = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = field[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }

    /// True when the certificate is missing, unreadable, or expires within `days`.
    func certNeedsRenewal(_ path: String, days: Int = 30) -> Bool {
        guard let expiry = certExpiry(path) else { return true }
        return expiry < Date().addingTimeInterval(TimeInterval(days * 86400))
    }

    /// True when the certificate was made for other names, for example before a TLD or domain change.
    /// makeCert writes the names to the .ext file next to the certificate.
    func certNamesChanged(_ site: Site) -> Bool {
        let ext = (try? String(contentsOfFile: "\(certs)/\(host(site)).ext", encoding: .utf8)) ?? ""
        return !ext.components(separatedBy: "\n").contains("subjectAltName = \(Self.sanList(hostnames(site)))")
    }

    static func sanList(_ hosts: [String]) -> String { hosts.map { "DNS:\($0),DNS:*.\($0)" }.joined(separator: ",") }

    /// Re-issues each secured site's certificate that is missing, expires within 30 days, or lacks a name.
    /// Herd and Valet never do this, so their sites break after a year. No prompt: the CA is already trusted.
    /// ponytail: runs on `corral start` only. Add a daily timer if Corral ever runs for months without a restart.
    @discardableResult
    func renewCertificates(within days: Int = 30) throws -> [String] {
        let due = sites().filter { config.secured.contains($0.name) && (certNeedsRenewal(certPath($0), days: days) || certNamesChanged($0)) }
        guard !due.isEmpty else { return [] }
        try ensureCA()
        for site in due { try makeCert(hostnames(site)) }
        return due.map(\.name)
    }

    func setSecure(_ site: Site, _ on: Bool) throws {
        if on {
            if try ensureCA() { try trustCA() }
            try makeCert(hostnames(site))
            config.secured.insert(site.name)
        } else {
            config.secured.remove(site.name)
            for ext in ["crt", "key", "csr", "ext"] { try? FileManager.default.removeItem(atPath: "\(certs)/\(host(site)).\(ext)") }
        }
        try apply()
    }

    // MARK: One-time system setup (the only part that needs root)

    /// True when the resolver file sends the domain to Corral's dnsmasq (and not, for example, to Herd's).
    static func resolverIsCorral(_ path: String) -> Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains("port \(dnsPort)") ?? false
    }

    var isInstalled: Bool { missingResolvers().isEmpty }

    // MARK: Sharing .test with Herd

    static let resolverBackup = "/Library/Application Support/Corral/herd-resolver-test"
    var ownsTest: Bool { Self.resolverIsCorral("/etc/resolver/" + Self.sharedTLD) }

    static var herdIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "de.beyondco.herd" }
    }

    private static let flushDNS = "dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true"

    /// Points .test at Corral. Keeps Herd's resolver file in a root-owned folder for `handback`.
    func takeoverScript() -> String {
        let file = "/etc/resolver/\(Self.sharedTLD)"
        return """
        set -e
        mkdir -p /etc/resolver "\((Self.resolverBackup as NSString).deletingLastPathComponent)"
        if [ -f \(file) ] && ! grep -q 'port \(Self.dnsPort)' \(file); then cp -p \(file) "\(Self.resolverBackup)"; fi
        printf 'nameserver 127.0.0.1\\nport \(Self.dnsPort)\\n' > \(file)
        \(Self.flushDNS)
        """
    }

    /// Gives .test back: restores Herd's resolver file, or removes Corral's if there was none.
    func handbackScript() -> String {
        let file = "/etc/resolver/\(Self.sharedTLD)"
        return """
        if grep -q 'port \(Self.dnsPort)' \(file) 2>/dev/null; then
            if [ -f "\(Self.resolverBackup)" ]; then mv "\(Self.resolverBackup)" \(file); else rm -f \(file); fi
        fi
        \(Self.flushDNS)
        """
    }

    func takeover() throws {
        if Self.herdIsRunning { throw CorralError("Quit Herd first. Herd takes .test back while it runs.") }
        try runAsAdmin(takeoverScript())
    }

    func install() throws {
        if config.tld == Self.sharedTLD && Self.herdIsRunning { throw CorralError("Quit Herd first. Herd takes .test back while it runs.") }
        try runAsAdmin(installScript())
    }

    func installScript() throws -> String {
        let boot = """
        /sbin/ifconfig lo0 alias \(Self.loopback) up
        printf 'rdr pass on lo0 inet proto tcp from any to \(Self.loopback) port 80 -> 127.0.0.1 port \(Self.httpPort)\\nrdr pass on lo0 inet proto tcp from any to \(Self.loopback) port 443 -> 127.0.0.1 port \(Self.httpsPort)\\n' | /sbin/pfctl -a com.apple/corral -f -
        /sbin/pfctl -E
        """
        let plist: [String: Any] = ["Label": Self.daemonLabel, "ProgramArguments": ["/bin/sh", "-c", boot], "RunAtLoad": true]
        let xml = String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        let resolvers = resolverTLDs(sites()).filter { $0 != Self.sharedTLD }
            .map { "printf 'nameserver 127.0.0.1\\nport \(Self.dnsPort)\\n' > /etc/resolver/\($0)" }
        return """
        set -e
        mkdir -p /etc/resolver
        \(resolvers.joined(separator: "\n"))
        \(config.tld == Self.sharedTLD ? takeoverScript() : "")
        cat > /Library/LaunchDaemons/\(Self.daemonLabel).plist <<'PLIST'
        \(xml)
        PLIST
        chown root:wheel /Library/LaunchDaemons/\(Self.daemonLabel).plist
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        launchctl bootstrap system /Library/LaunchDaemons/\(Self.daemonLabel).plist
        """
    }

    func uninstallScript() -> String {
        handbackScript() + """

        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(Self.daemonLabel).plist
        for f in /etc/resolver/*; do grep -q 'port \(Self.dnsPort)' "$f" 2>/dev/null && rm -f "$f"; done
        /sbin/pfctl -a com.apple/corral -F all 2>/dev/null || true
        /sbin/ifconfig lo0 -alias \(Self.loopback) 2>/dev/null || true
        """
    }

    /// One admin prompt (like Herd's helper install), via the standard macOS authorization dialog.
    func runAsAdmin(_ script: String) throws {
        try mkdirs(conf)
        let path = conf + "/admin.sh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try sh("/usr/bin/osascript", ["-e", "do shell script \"/bin/sh \" & quoted form of \"\(escaped)\" with administrator privileges"])
    }

    // MARK: Migrate from Laravel Herd

    struct HerdImport {
        var parked: [String] = []
        var links: [String] = []
        var secured: [String] = []
        var skipped: [String] = []                  // Herd certificates with no matching site
        var php: String?
        var isolated: [String: String] = [:]        // site -> PHP version
        var proxies: [String: String] = [:]         // site -> upstream URL
        var installs: [String] = []                 // PHP versions to download
        var ini: [String: [String: String]] = [:]   // PHP version -> php.ini values that differ
        var node: [String] = []                     // sites with .nvmrc. Corral does not manage Node.

        var summary: [String] {
            func list(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
            var out = [
                "Parked folders: \(list(parked))",
                "Links: \(list(links))",
                "Sites to serve over HTTPS: \(secured.count)\(secured.isEmpty ? "" : " (\(secured.joined(separator: ", ")))")",
                "Global PHP: \(php ?? "not found in Herd")",
            ]
            if !isolated.isEmpty { out.append("PHP for one site: \(list(isolated.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }))") }
            if !installs.isEmpty { out.append("PHP to download: \(list(installs))") }
            for (v, values) in ini.sorted(by: { $0.key < $1.key }) {
                out.append("php.ini for PHP \(v): \(list(values.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }))")
            }
            if !proxies.isEmpty { out.append("Proxies: \(list(proxies.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value)" }))") }
            if !skipped.isEmpty { out.append("Certificates with no site (skipped): \(list(skipped))") }
            if !node.isEmpty { out.append("Sites with .nvmrc (Corral does not manage Node, keep nvm): \(list(node))") }
            return out
        }
    }

    static let herdHome = NSHomeDirectory() + "/Library/Application Support/Herd"
    static var herdFound: Bool { FileManager.default.fileExists(atPath: herdHome + "/config/valet/config.json") }

    /// php.ini lines that only work inside Herd: its extension, dump loader and CA bundle.
    static let herdOnlyIni: Set<String> = ["extension", "zend_extension", "auto_prepend_file", "auto_append_file", "curl.cainfo", "openssl.cafile"]

    /// Copies Herd's parked folders, links, secured sites, PHP versions (global and per site), php.ini values
    /// and proxies. Reads Herd's files, never writes them. A dry run changes nothing and returns the plan.
    func importHerd(from herd: String = herdHome, trust: Bool = true, dryRun: Bool = false) throws -> HerdImport {
        let fm = FileManager.default
        let valet = herd + "/config/valet", sitesDir = valet + "/Sites"
        guard let data = fm.contents(atPath: valet + "/config.json"),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorralError("No Herd configuration found in \(valet).")
        }
        func norm(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
        func version(_ m: some StringProtocol, _ n: some StringProtocol) -> String { "\(m).\(n)" }
        let saved = config
        defer { if dryRun { config = saved } } // a dry run works on the config, then puts it back
        var result = HerdImport()

        // Herd's own Sites folder holds only its links. Those come next.
        for path in (json["paths"] as? [String] ?? []).map(norm)
        where path != norm(sitesDir) && isDir(path) && !config.parked.map(norm).contains(path) {
            config.parked.append(path)
            result.parked.append(path)
        }

        // Links: Sites/<name> is a symlink to the project folder.
        let existing = Dictionary(sites().map { ($0.name, norm($0.path)) }, uniquingKeysWith: { a, _ in a })
        for entry in ((try? fm.contentsOfDirectory(atPath: sitesDir)) ?? []).sorted() {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: "\(sitesDir)/\(entry)"), isDir(target) else { continue }
            let name = Self.slug(entry)
            if existing[name] == norm(target) { continue } // already served under this name
            config.links[name] = norm(target)
            result.links.append(name)
        }

        // Nginx/<site>.<tld>: a proxy (`herd proxy`) or a site with its own PHP version (`herd isolate`).
        let tld = json["tld"] as? String ?? "test"
        var names = Set(sites().map(\.name))
        for file in ((try? fm.contentsOfDirectory(atPath: valet + "/Nginx")) ?? []).sorted() where file.hasSuffix("." + tld) {
            let name = Self.slug(String(file.dropLast(tld.count + 1)))
            let text = (try? String(contentsOfFile: "\(valet)/Nginx/\(file)", encoding: .utf8)) ?? ""
            if !names.contains(name), let m = text.firstMatch(of: /proxy_pass\s+(https?:\/\/[^;\s]+);/) {
                config.proxies[name] = String(m.1)
                result.proxies[name] = String(m.1)
                names.insert(name)
            } else if names.contains(name), config.isolated[name] == nil,
                      let m = text.firstMatch(of: /ISOLATED_PHP_VERSION=(?:php@)?(\d)\.?(\d+)/) ?? text.firstMatch(of: /herd(\d)(\d+)\.sock/) {
                config.isolated[name] = version(m.1, m.2)
                result.isolated[name] = version(m.1, m.2)
            }
        }

        // Secured sites: Certificates/<site>.<tld>.crt
        let all = sites()
        for file in ((try? fm.contentsOfDirectory(atPath: valet + "/Certificates")) ?? []).sorted() where file.hasSuffix(".\(tld).crt") {
            let name = Self.slug(String(file.dropLast(tld.count + 5)))
            guard let site = all.first(where: { $0.name == name }) else { result.skipped.append(name); continue }
            if config.secured.contains(name) { continue }
            if !dryRun {
                if try ensureCA(), trust { try trustCA() }
                try makeCert(hostnames(site))
            }
            config.secured.insert(name)
            result.secured.append(name)
        }

        // Global PHP: herd.sock links to herd84.sock for PHP 8.4.
        if let target = try? fm.destinationOfSymbolicLink(atPath: herd + "/herd.sock"),
           let m = (target as NSString).lastPathComponent.firstMatch(of: /^herd(\d)(\d+)\.sock$/) {
            config.php = version(m.1, m.2)
            result.php = config.php
        }

        let installed = phpVersions()
        result.installs = Self.sortVersions(Set([result.php].compactMap { $0 } + result.isolated.values).filter { installed[$0] == nil })
        if !dryRun { for v in result.installs { try installPHP(v) } }

        // php.ini values from config/php/84/php.ini, for the versions Corral has or installs now.
        for dir in ((try? fm.contentsOfDirectory(atPath: herd + "/config/php")) ?? []).sorted() {
            guard let m = dir.wholeMatch(of: /(\d)(\d+)/), let text = try? String(contentsOfFile: "\(herd)/config/php/\(dir)/php.ini", encoding: .utf8) else { continue }
            let v = version(m.1, m.2)
            let fpm = phpVersions()[v]
            guard fpm != nil || result.installs.contains(v) else { continue }
            let current = fpm.flatMap { try? String(contentsOfFile: iniPath(v, $0), encoding: .utf8) } ?? Self.defaultPhpIni
            var values: [String: String] = [:]
            for line in text.components(separatedBy: "\n") where !line.hasPrefix(";") && !line.hasPrefix("[") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !Self.herdOnlyIni.contains(parts[0]), !parts[1].contains("Herd") else { continue }
                values[parts[0]] = parts[1]
            }
            values = values.filter { Self.iniValue(current, $0.key) != $0.value }
            if values.isEmpty { continue }
            result.ini[v] = values
            if !dryRun { try savePHPSettings(v, ini: values, pool: config.fpm[v] ?? FpmPool()) }
        }

        result.node = sites().filter { $0.proxy == nil && fm.fileExists(atPath: $0.path + "/.nvmrc") }.map(\.name)
        if !dryRun { try apply() }
        return result
    }

    /// Quits Herd and waits up to 10 seconds. Herd stops its own nginx, dnsmasq and php-fpm.
    static func quitHerd() throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "de.beyondco.herd")
        for app in apps { app.terminate() }
        for _ in 0..<100 where apps.contains(where: { kill($0.processIdentifier, 0) == 0 }) { usleep(100_000) }
        if apps.contains(where: { kill($0.processIdentifier, 0) == 0 }) { throw CorralError("Herd did not quit. Quit it from its menu, then try again.") }
    }

    /// Herd's login item. Without it, Herd does not start at login and take .test back.
    /// ponytail: only the classic login item that System Events lists. A Herd that uses SMAppService needs System Settings.
    static var herdLoginItem: Bool {
        (try? sh("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"]))?
            .components(separatedBy: ", ").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Herd" } ?? false
    }

    static func setHerdLoginItem(_ on: Bool) throws {
        let script = on ? "make login item at end with properties {path:\"/Applications/Herd.app\", hidden:false}" : "delete login item \"Herd\""
        try sh("/usr/bin/osascript", ["-e", "tell application \"System Events\" to \(script)"])
    }

    /// The last step of a move from Herd: serve .test, start the services, then check every site.
    func finishHerdMove() throws -> [(site: String, problem: String)] {
        if Self.herdIsRunning { try Self.quitHerd() }
        try start()
        if !ownsTest { try config.tld == Self.sharedTLD ? install() : takeover() }
        return checkSites()
    }

    /// Requests each PHP site through nginx and names the likely cause of an error. Herd and Corral share the
    /// same databases, so most failures are a database or a `composer install` that Herd's copy had and this one lacks.
    func checkSites() -> [(site: String, problem: String)] {
        let installed = phpVersions()
        var out: [(String, String)] = []
        for site in sites() where site.proxy == nil {
            let https = config.secured.contains(site.name), host = host(site)
            let port = https ? "443:127.0.0.1:\(Self.httpsPort)" : "80:127.0.0.1:\(Self.httpPort)"
            let log = php(for: site, installed).map { "\(logs)/php\($0)-fpm.log" }
            let logStart = log.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? UInt64 } ?? 0
            let body = FileManager.default.temporaryDirectory.appendingPathComponent("corral-check-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: body) }
            let status = (try? sh("/usr/bin/curl", ["-sk", "--max-time", "20", "-o", body, "-w", "%{http_code}",
                                                    "--connect-to", "\(host):\(port)", url(site).absoluteString])) ?? "000"
            var text = (try? String(contentsOfFile: body, encoding: .utf8)) ?? ""
            if let log, let h = FileHandle(forReadingAtPath: log) {
                try? h.seek(toOffset: logStart)
                text += String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            }
            if let problem = Self.diagnose(status: Int(status) ?? 0, text) { out.append((site.name, problem)) }
        }
        return out
    }

    static func diagnose(status: Int, _ text: String) -> String? {
        let causes: [(String, String)] = [
            ("vendor/autoload.php", "missing Composer packages: run composer install"),
            ("[1049]", "missing database"),
            ("Unknown database", "missing database"),
            ("[1045]", "wrong database user or password"),
            ("Access denied for user", "wrong database user or password"),
            ("[2002]", "the database server does not run"),
            ("Error establishing a database connection", "WordPress cannot connect to its database"),
            ("could not find driver", "a PHP database extension is missing"),
            ("No Corral site here", "nginx has no site for this name"),
        ]
        if let cause = causes.first(where: { text.contains($0.0) }) { return cause.1 }
        if status == 0 { return "no response" }
        return status >= 500 ? "HTTP \(status)" : nil
    }

    // MARK: Insights

    /// Log files for the Insights window: the site's Laravel and WordPress logs, then Corral's own.
    func logFiles(_ site: Site?) -> [String] {
        let fm = FileManager.default
        func logsIn(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".log") }.sorted(by: >).map { "\(dir)/\($0)" }
        }
        var out: [String] = []
        if let site, site.proxy == nil {
            out += logsIn(site.path + "/storage/logs")
            out += [site.docroot + "/wp-content/debug.log"].filter { fm.fileExists(atPath: $0) }
        }
        return out + logsIn(logs).reversed()
    }

    /// The end of a file, at most `bytes` long, from the start of a line.
    static func tail(_ path: String, bytes: UInt64 = 256 * 1024) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return size > bytes ? String(text.drop { $0 != "\n" }.dropFirst()) : text
    }

    struct Dump: Identifiable, Sendable {
        let id = UUID()
        let time: Date
        let text: String     // CliDumper output with SGR color codes, see dumpDecoder
        let source: String   // file:line of the dump() call
        let request: String  // "GET /path", or the command line
    }

    /// Turns one VarDumper payload (base64 of serialize([$data, $context])) into text.
    /// Swift cannot read PHP's serialized objects, so PHP does it with the site's own symfony/var-dumper.
    /// The script loads only VarDumper classes, not the project's autoloader.
    static let dumpDecoder = #"""
    <?php
    error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED); // old var-dumper versions warn on new PHP and break the JSON
    $raw = base64_decode(stream_get_contents(STDIN));
    [, $context] = unserialize($raw, ['allowed_classes' => false]);
    $file = $context['source']['file'] ?? '';
    for ($dir = dirname($file); strlen($dir) > 1 && !is_dir("$dir/vendor/symfony/var-dumper"); $dir = dirname($dir));
    $base = is_dir("$dir/vendor/symfony/var-dumper") ? "$dir/vendor/symfony/var-dumper/" : ($argv[1] ?? '');
    spl_autoload_register(function ($class) use ($base) {
        $prefix = 'Symfony\\Component\\VarDumper\\';
        if (str_starts_with($class, $prefix) && is_file($f = $base . strtr(substr($class, strlen($prefix)), '\\', '/') . '.php')) require $f;
    });
    if (!class_exists(Symfony\Component\VarDumper\Cloner\Data::class)) { fwrite(STDERR, "symfony/var-dumper not found for $file"); exit(1); }
    [$data] = unserialize($raw, ['allowed_classes' => [Symfony\Component\VarDumper\Cloner\Data::class, Symfony\Component\VarDumper\Cloner\Stub::class]]);
    $dumper = new Symfony\Component\VarDumper\Dumper\CliDumper(null, null, 0);
    $dumper->setColors(true);
    $dumper->setDisplayOptions(['fileLinkFormat' => false]); // no source links: they add a "^" to the text
    // One SGR code per token type. Dump.styled maps the codes to colors.
    $dumper->setStyles(['default' => '39', 'public' => '39', 'protected' => '39', 'private' => '39', 'num' => '31', 'const' => '32',
        'str' => '33', 'note' => '34', 'ref' => '35', 'meta' => '36', 'key' => '37', 'index' => '90']);
    $request = $context['request'] ?? null;
    echo json_encode([
        'text' => $dumper->dump($data, true),
        'source' => $file === '' ? '' : $file . ':' . ($context['source']['line'] ?? ''),
        'request' => $request ? trim(($request['method'] ?? '') . ' ' . ($request['uri'] ?? '')) : ($context['cli']['command_line'] ?? ''),
        'time' => $context['timestamp'] ?? microtime(true),
    ], JSON_INVALID_UTF8_SUBSTITUTE);
    """#

    func decodeDump(_ payload: String) throws -> Dump {
        let installed = phpVersions()
        guard let v = globalPHP(installed), let fpm = installed[v] else { throw CorralError("No PHP to read the dump.") }
        try mkdirs(conf)
        let script = conf + "/dump-decoder.php", input = run + "/dump-\(UUID().uuidString)"
        try Self.dumpDecoder.write(toFile: script, atomically: true, encoding: .utf8)
        try mkdirs(run)
        try payload.write(toFile: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: input) }
        // A dump() call outside a site still needs VarDumper: use the first site that has it.
        let fallback = sites().map { $0.path + "/vendor/symfony/var-dumper/" }.first { FileManager.default.fileExists(atPath: $0) } ?? ""
        let out = try Self.sh("/bin/sh", ["-c", "exec \"$0\" \"$1\" \"$2\" < \"$3\"", cliPath(fpm), script, fallback, input])
        guard let json = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
            throw CorralError("Could not read a dump: \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
        return Dump(time: Date(timeIntervalSince1970: json["time"] as? Double ?? Date().timeIntervalSince1970),
                    text: json["text"] as? String ?? "", source: json["source"] as? String ?? "", request: json["request"] as? String ?? "")
    }

    /// Points a Laravel site's mail at Corral. Keeps the first original as .env.corral.bak, like Herd's .env.herd-services.bak.
    /// The SMTP user name is the site name, so the inbox shows which site sent a message.
    func useCorralMail(_ site: Site) throws {
        let env = site.path + "/.env", backup = env + ".corral.bak"
        guard var text = try? String(contentsOfFile: env, encoding: .utf8) else { throw CorralError("\(site.name) has no .env file.") }
        if !FileManager.default.fileExists(atPath: backup) { try text.write(toFile: backup, atomically: true, encoding: .utf8) }
        var values = ["MAIL_MAILER": "smtp", "MAIL_HOST": "127.0.0.1", "MAIL_PORT": "2525", "MAIL_USERNAME": site.name]
        for key in ["MAIL_ENCRYPTION", "MAIL_SCHEME", "MAIL_PASSWORD"] where Self.iniValue(text, key) != nil { values[key] = "null" }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) { text = Self.setEnv(text, key, value) }
        try text.write(toFile: env, atomically: true, encoding: .utf8)
    }

    /// Like setIni, for KEY=value lines. A new key goes after the last MAIL_ line, or at the end.
    static func setEnv(_ env: String, _ key: String, _ value: String) -> String {
        var lines = env.components(separatedBy: "\n")
        if let i = lines.lastIndex(where: { $0.hasPrefix(key + "=") }) { lines[i] = "\(key)=\(value)"; return lines.joined(separator: "\n") }
        let at = lines.lastIndex { $0.hasPrefix("MAIL_") }.map { $0 + 1 } ?? (lines.last == "" ? lines.count - 1 : lines.count)
        lines.insert("\(key)=\(value)", at: at)
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    func mkdirs(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func readPid(_ file: String) -> pid_t? {
        (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func alive(_ pidFile: String) -> Bool { readPid(pidFile).map { kill($0, 0) == 0 } ?? false }

    @discardableResult
    func sh(_ exe: String, _ args: [String]) throws -> String { try Self.sh(exe, args) }

    /// Output goes to a temp file, not a pipe: daemonizing children keep inherited fds open.
    @discardableResult
    static func sh(_ exe: String, _ args: [String]) throws -> String {
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("corral-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }
        let handle = try FileHandle(forWritingTo: outURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try handle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        guard p.terminationStatus == 0 else {
            throw CorralError("\((exe as NSString).lastPathComponent) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}
