import Foundation

struct Config: Codable, Equatable {
    var tld = "internal"                 // ICANN-reserved private TLD, so it can't clash with Herd's .test
    var php: String?                     // global PHP version; nil = newest installed
    var parked: [String] = []
    var links: [String: String] = [:]    // site name -> directory
    var secured: Set<String> = []
    var isolated: [String: String] = [:] // site name -> PHP version
    var proxies: [String: String] = [:]  // site name -> upstream URL

    init() {}

    // Missing keys keep their defaults, so a config.json from an older Corral still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        tld = try c.decodeIfPresent(String.self, forKey: .tld) ?? d.tld
        php = try c.decodeIfPresent(String.self, forKey: .php)
        parked = try c.decodeIfPresent([String].self, forKey: .parked) ?? d.parked
        links = try c.decodeIfPresent([String: String].self, forKey: .links) ?? d.links
        secured = try c.decodeIfPresent(Set<String>.self, forKey: .secured) ?? d.secured
        isolated = try c.decodeIfPresent([String: String].self, forKey: .isolated) ?? d.isolated
        proxies = try c.decodeIfPresent([String: String].self, forKey: .proxies) ?? d.proxies
    }
}

/// Optional `.corral.json` in a site folder.
struct SiteOverrides: Codable, Equatable {
    var root: String?   // document root, relative to the site folder
    var nginx: String?  // extra directives inside the site's server block
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

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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

    func url(_ site: Site) -> URL {
        URL(string: (config.secured.contains(site.name) ? "https://" : "http://") + host(site))!
    }

    // MARK: PHP

    var phpDir: String { home + "/php" }
    var binDir: String { home + "/bin" }

    // ponytail: add a new minor version here when static-php-cli publishes it.
    static let phpChoices = ["8.5", "8.4", "8.3", "8.2", "8.1"]

    /// version ("8.5") -> php-fpm path. Corral's own static builds win over Homebrew's opt/php and opt/php@X.Y.
    func phpVersions() -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: brew + "/opt")) ?? [] where name == "php" || name.hasPrefix("php@") {
            let fpm = "\(brew)/opt/\(name)/sbin/php-fpm"
            guard fm.isExecutableFile(atPath: fpm),
                  let cellar = try? fm.destinationOfSymbolicLink(atPath: "\(brew)/opt/\(name)") else { continue }
            // "../Cellar/php/8.5.11_1" -> "8.5"
            let v = URL(fileURLWithPath: cellar).lastPathComponent.split(separator: ".").prefix(2).joined(separator: ".")
            out[v] = fpm
        }
        for v in (try? fm.contentsOfDirectory(atPath: phpDir)) ?? [] where fm.isExecutableFile(atPath: "\(phpDir)/\(v)/php-fpm") {
            out[v] = "\(phpDir)/\(v)/php-fpm"
        }
        return out
    }

    func isManaged(_ fpm: String) -> Bool { fpm.hasPrefix(phpDir + "/") }

    func cliPath(_ fpm: String) -> String {
        isManaged(fpm) ? (fpm as NSString).deletingLastPathComponent + "/php" : fpm.replacingOccurrences(of: "/sbin/php-fpm", with: "/bin/php")
    }

    /// Static builds keep php.ini next to the binaries. Homebrew builds use Homebrew's php.ini.
    func iniArgs(_ fpm: String) -> [String] {
        isManaged(fpm) ? ["-c", (fpm as NSString).deletingLastPathComponent + "/php.ini"] : []
    }

    static let defaultPhpIni = """
    memory_limit = 512M
    upload_max_filesize = 512M
    post_max_size = 512M
    max_execution_time = 120
    display_errors = On
    error_reporting = E_ALL
    date.timezone = UTC
    ; Static builds have no CA bundle. Use the macOS bundle.
    curl.cainfo = /etc/ssl/cert.pem
    openssl.cafile = /etc/ssl/cert.pem

    """

    /// Downloads the newest static PHP build for a minor version from static-php-cli (the "common" extension set).
    func installPHP(_ minor: String) throws {
        let fm = FileManager.default
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let base = "https://dl.static-php.dev/static-php-cli/common/"
        let listing = try sh("/usr/bin/curl", ["-fsSL", base + "?format=json"])
        let regex = try NSRegularExpression(pattern: "php-\(NSRegularExpression.escapedPattern(for: minor))\\.(\\d+)-fpm-macos-\(arch)\\.tar\\.gz")
        let patches = regex.matches(in: listing, range: NSRange(listing.startIndex..., in: listing))
            .compactMap { Range($0.range(at: 1), in: listing).flatMap { Int(listing[$0]) } }
        guard let patch = patches.max() else { throw CorralError("No static PHP \(minor) build for macOS \(arch).") }

        let dir = "\(phpDir)/\(minor)", tmp = dir + ".download"
        try? fm.removeItem(atPath: tmp)
        try mkdirs(tmp)
        for kind in ["fpm", "cli"] {
            let tarball = "\(tmp)/\(kind).tar.gz"
            try sh("/usr/bin/curl", ["-fsSL", "\(base)php-\(minor).\(patch)-\(kind)-macos-\(arch).tar.gz", "-o", tarball])
            try sh("/usr/bin/tar", ["xzf", tarball, "-C", tmp])
            try fm.removeItem(atPath: tarball)
        }
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
            let names = "\(host(site)) *.\(host(site))"
            let sock = php(for: site, installed).map(self.sock) ?? "\(run)/no-php.sock"
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

    func fpmConf(_ version: String) -> String {
        let overrides = phpOverrides().map { "php_value[\($0.0)] = \"\($0.1)\"\n" }.joined()
        return """
        [global]
        pid = "\(run)/php\(version)-fpm.pid"
        error_log = "\(logs)/php\(version)-fpm.log"
        daemonize = yes

        [corral]
        listen = "\(sock(version))"
        listen.mode = 0600
        pm = dynamic
        pm.max_children = 5
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        catch_workers_output = yes
        \(overrides)
        """
    }

    func writeConfigs() throws {
        for d in [conf, logs, certs, run + "/tmp"] { try mkdirs(d) }
        let installed = phpVersions()
        let sites = sites()
        if let bad = sites.first(where: { $0.overridesError != nil }) {
            throw CorralError("Invalid \(bad.path)/.corral.json: \(bad.overridesError!)")
        }
        try nginxConf(sites: sites, installed: installed).write(toFile: conf + "/nginx.conf", atomically: true, encoding: .utf8)
        for v in installed.keys { try fpmConf(v).write(toFile: "\(conf)/php\(v)-fpm.conf", atomically: true, encoding: .utf8) }
        try writeShims(installed)
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

    /// Idempotent: writes configs, starts whatever is down, reloads nginx if it's already up.
    func start() throws {
        try writeConfigs()
        let installed = phpVersions()
        if installed.isEmpty { throw CorralError("No PHP found. Install it with: corral php:install \(Self.phpChoices[0])") }
        for v in neededPHP(installed) where !alive("\(run)/php\(v)-fpm.pid") {
            try sh(installed[v]!, ["--fpm-config", "\(conf)/php\(v)-fpm.conf"] + iniArgs(installed[v]!))
        }
        if !alive(run + "/dnsmasq.pid") {
            try sh(tool("dnsmasq"), [
                "--conf-file=/dev/null", "--port=\(Self.dnsPort)", "--listen-address=127.0.0.1", "--bind-interfaces",
                "--no-resolv", "--no-hosts", "--address=/\(config.tld)/\(Self.loopback)", "--pid-file=\(run)/dnsmasq.pid",
            ])
        }
        let nginx = try tool("nginx")
        try sh(nginx, nginxArgs + ["-t", "-q"])
        if isRunning {
            try sh(nginx, nginxArgs + ["-s", "reload"])
            usleep(250_000) // ponytail: reload is async (<100ms observed); poll worker PIDs if this ever races
        } else {
            try sh(nginx, nginxArgs)
        }
    }

    func stop() {
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

    func makeCert(_ host: String) throws {
        let base = "\(certs)/\(host)"
        try """
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(host),DNS:*.\(host)
        """.write(toFile: base + ".ext", atomically: true, encoding: .utf8)
        try sh("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(host)",
                                    "-keyout", base + ".key", "-out", base + ".csr"])
        // 397 days: Apple rejects longer-lived leaf certificates (Valet's Site.php has the same cap).
        try sh("/usr/bin/openssl", ["x509", "-req", "-sha256", "-days", "397", "-in", base + ".csr",
                                    "-CA", caPem, "-CAkey", certs + "/CorralCA.key",
                                    "-set_serial", "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16),
                                    "-extfile", base + ".ext", "-out", base + ".crt"])
    }

    func setSecure(_ site: Site, _ on: Bool) throws {
        if on {
            if try ensureCA() { try trustCA() }
            try makeCert(host(site))
            config.secured.insert(site.name)
        } else {
            config.secured.remove(site.name)
            for ext in ["crt", "key", "csr", "ext"] { try? FileManager.default.removeItem(atPath: "\(certs)/\(host(site)).\(ext)") }
        }
        try apply()
    }

    // MARK: One-time system setup (the only part that needs root)

    var isInstalled: Bool { FileManager.default.fileExists(atPath: "/etc/resolver/" + config.tld) }

    func installScript() throws -> String {
        let boot = """
        /sbin/ifconfig lo0 alias \(Self.loopback) up
        printf 'rdr pass on lo0 inet proto tcp from any to \(Self.loopback) port 80 -> 127.0.0.1 port \(Self.httpPort)\\nrdr pass on lo0 inet proto tcp from any to \(Self.loopback) port 443 -> 127.0.0.1 port \(Self.httpsPort)\\n' | /sbin/pfctl -a com.apple/corral -f -
        /sbin/pfctl -E
        """
        let plist: [String: Any] = ["Label": Self.daemonLabel, "ProgramArguments": ["/bin/sh", "-c", boot], "RunAtLoad": true]
        let xml = String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        return """
        set -e
        mkdir -p /etc/resolver
        printf 'nameserver 127.0.0.1\\nport \(Self.dnsPort)\\n' > /etc/resolver/\(config.tld)
        cat > /Library/LaunchDaemons/\(Self.daemonLabel).plist <<'PLIST'
        \(xml)
        PLIST
        chown root:wheel /Library/LaunchDaemons/\(Self.daemonLabel).plist
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        launchctl bootstrap system /Library/LaunchDaemons/\(Self.daemonLabel).plist
        """
    }

    func uninstallScript() -> String {
        """
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(Self.daemonLabel).plist /etc/resolver/\(config.tld)
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

    // MARK: Helpers

    func mkdirs(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func readPid(_ file: String) -> pid_t? {
        (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func alive(_ pidFile: String) -> Bool { readPid(pidFile).map { kill($0, 0) == 0 } ?? false }

    /// Output goes to a temp file, not a pipe: daemonizing children keep inherited fds open.
    @discardableResult
    func sh(_ exe: String, _ args: [String]) throws -> String {
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
