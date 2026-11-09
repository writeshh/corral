import AppKit

enum CLI {
    static let usage = """
    Corral: local PHP sites on .<tld>, Herd-style.

      install | uninstall          one-time system setup (resolver, loopback alias, pf 80/443 redirect)
      takeover | handback          send .test to Corral, or give it back to Herd
      migrate:herd [--dry-run]     move from Herd in one step: copy its sites, PHP versions, php.ini values
                   [--yes]         and proxies, quit Herd, take over .test, then check every site
      migrate:herd --undo          give .test back to Herd. Herd's own files never change.
      import:herd                  only copy the Herd settings (the first part of migrate:herd)
      start | stop | restart       nginx, dnsmasq, php-fpm
      status                       service state
      park [dir] | forget [dir]    serve every subfolder of dir as <folder>.<tld>
      link [name] | unlink [name]  serve the current folder as <name>.<tld>
      proxy <name> <url>           serve a dev server as <name>.<tld>, for example
                                   corral proxy shop http://shop.localhost:1355
      unproxy <name>               remove a proxy site
      run [--name n] [--port p] <command>
                                   run a dev server and serve it at https://<folder>.<tld> until it stops,
                                   for example corral run npm run dev. Corral picks a free port and sets PORT.
                                   Use --port for servers that ignore PORT, such as Vite.
      sites                        list sites
      secure [site] | unsecure [site]
      secured                      list secured sites with the expiry date of each certificate
      use <ver>                    set the global PHP version
      isolate <ver> [site] | unisolate [site]
      php:list                     installed PHP versions (Corral builds only)
      php:install <ver>            download a static PHP build, for example 8.4
      php:uninstall <ver>          remove a PHP version that Corral installed
      xdebug [on|off] [--mode m] [--host h] [--port n] [--start yes|trigger]
                                   debug pool: a second php-fpm with Xdebug. A request goes to it only
                                   with an XDEBUG_SESSION or XDEBUG_TRIGGER cookie or query argument.
      wp:import <dump> [name]      import a SQL dump (.sql or .sql.gz) into the site's database, then replace
                                   the old address with https://<name>.<tld>. Needs wp-config.php.
      wp:setup [name]              set up WordPress in the current folder: database, core, config, HTTPS,
                                   debug settings. Uses Corral's wp and php.
      laravel:setup [name] [--seed]  set up a cloned Laravel project: composer, .env, key, database,
                                   migrations, npm build, HTTPS. Uses Corral's composer and php.
      new <name> [options]         create a Laravel project with `laravel new` in the parked folder (the current
                                   folder if it is parked), then serve it at https://<name>.<tld>. Options go to
                                   the installer. Corral adds --no-boost unless you pass --boost.
      mail [inbox]                 list caught mail, newest first (the menu bar app catches it on 127.0.0.1:2525)
      mail:show [n] | mail:links [n]   print message n (1 = newest) as raw .eml, or only its links
      mail:clear                   delete all caught mail
      tools                        versions of composer, wp, and laravel
      tools:update [name]          update composer, wp, or laravel (all by default). laravel:update is the same for laravel.
      open [site]
      trust                        trust the local CA in your login keychain
      update                       install the newest release from GitHub

    Run with no arguments to launch the menu bar app.
    """

    static func run(_ args: [String]) -> Int32 {
        let corral = Corral()
        let cwd = FileManager.default.currentDirectoryPath
        let arg1 = args.count > 1 ? args[1] : nil
        let arg2 = args.count > 2 ? args[2] : nil
        do {
            switch args[0] {
            case "install":
                try corral.install()
                if try corral.addToPath() { print("Put Corral's bin folder first in PATH in ~/.zshrc. Open a new terminal.") }
                let names = corral.dnsNames(corral.sites()).map { "*.\($0)" }.joined(separator: ", ")
                print("Installed. \(names) -> \(Corral.loopback), ports 80/443 -> \(Corral.httpPort)/\(Corral.httpsPort).")
            case "uninstall":
                corral.stop()
                try corral.runAsAdmin(corral.uninstallScript())
                if try corral.removeFromPath() { print("Removed Corral's PATH line from ~/.zshrc.") }
                print("System changes removed. Config left in \(corral.home).")
            case "start", "restart":
                if args[0] == "restart" { corral.stop() }
                try corral.start()
                fallthrough
            case "status":
                for (name, up) in corral.status() { print("\(up ? "●" : "○") \(name)") }
                print(".\(Corral.sharedTLD) goes to \(corral.ownsTest ? "Corral" : "Herd (or nothing)")")
                let missing = corral.missingResolvers()
                if missing == [Corral.sharedTLD] && Corral.herdIsRunning {
                    print("Herd serves .test, the main TLD. Quit Herd, then run `corral install`.")
                } else if !missing.isEmpty {
                    print("Not resolving yet: \(missing.map { "." + $0 }.joined(separator: ", ")). Run `corral install`.")
                }
            case "import:herd":
                try corral.importHerd().summary.forEach { print($0) }
            case "migrate:herd":
                let flags = Set(args.dropFirst())
                if flags.contains("--undo") {
                    try corral.runAsAdmin(corral.handbackScript())
                    if !Corral.herdLoginItem, confirm("Add Herd to your login items again?", flags) { try Corral.setHerdLoginItem(true) }
                    print(".\(Corral.sharedTLD) goes to Herd again. Start Herd to use it. Corral keeps its own settings.")
                    break
                }
                let plan = try corral.importHerd(dryRun: true)
                print("Corral will copy this from Herd:")
                plan.summary.forEach { print("  " + $0) }
                print("Then it quits Herd, serves .\(Corral.sharedTLD), and checks every site.")
                if flags.contains("--dry-run") { print("Dry run: nothing changed."); break }
                guard confirm("Continue?", flags) else { break }
                if Corral.herdLoginItem, confirm("Remove Herd from your login items, so it does not take .test back at login?", flags) {
                    try Corral.setHerdLoginItem(false)
                }
                _ = try corral.importHerd()
                let problems = try corral.finishHerdMove()
                print(problems.isEmpty ? "Done. Every site answers." : "Done. These sites need attention:")
                for p in problems { print("  \(p.site): \(p.problem)") }
                print("To go back: corral migrate:herd --undo")
            case "takeover":
                try corral.takeover()
                print(".\(Corral.sharedTLD) now goes to Corral. Run `corral handback` before you start Herd again.")
            case "handback":
                try corral.runAsAdmin(corral.handbackScript())
                print(".\(Corral.sharedTLD) goes to Herd again. You can start Herd now.")
            case "stop":
                corral.stop()
            case "park":
                let dir = absolute(arg1 ?? cwd, cwd)
                if !corral.config.parked.contains(dir) { corral.config.parked.append(dir) }
                try corral.apply()
                print("Parked \(dir)")
            case "forget":
                let dir = absolute(arg1 ?? cwd, cwd)
                corral.config.parked.removeAll { $0 == dir }
                try corral.apply()
            case "link":
                let name = Corral.slug(arg1 ?? (cwd as NSString).lastPathComponent)
                corral.config.links[name] = cwd
                try corral.apply()
                print("http://\(name).\(corral.config.tld) -> \(cwd)")
            case "unlink":
                let site = try corral.site(named: arg1)
                corral.config.links[site.name] = nil
                try corral.apply()
            case "proxy":
                guard let arg1, let arg2, let url = URL(string: arg2), ["http", "https"].contains(url.scheme), url.host != nil else {
                    throw CorralError("Usage: corral proxy <name> <http(s)://host:port>")
                }
                let name = Corral.slug(arg1)
                corral.config.proxies[name] = arg2
                try corral.apply()
                print("http://\(name).\(corral.config.tld) -> \(arg2)")
            case "unproxy":
                guard let arg1, corral.config.proxies.removeValue(forKey: Corral.slug(arg1)) != nil else {
                    throw CorralError("No proxy named '\(arg1 ?? "")'.")
                }
                try corral.apply()
            case "run":
                let (name, port, command) = try runOptions(Array(args.dropFirst()), cwd: cwd)
                return try runDevServer(corral, name: name, port: port, command: command)
            case "sites":
                let installed = corral.phpVersions()
                for s in corral.sites() {
                    let detail = s.proxy == nil ? "php \(corral.php(for: s, installed) ?? "-")\t\(s.docroot)" : "proxy\t\(s.path)"
                    print("\(corral.url(s).absoluteString)\t\(detail)")
                }
                for app in Corral.portlessApps() { print("\(app.url.absoluteString)\tportless\tlocalhost:\(app.port)") }
            case "secured":
                let renewed = try corral.renewCertificates()
                if !renewed.isEmpty { print("Renewed: \(renewed.joined(separator: ", "))") }
                for s in corral.sites() where corral.config.secured.contains(s.name) {
                    let expiry = corral.certExpiry(corral.certPath(s)).map { $0.formatted(date: .abbreviated, time: .omitted) }
                    print("\(corral.host(s))\texpires \(expiry ?? "unknown")")
                }
            case "secure", "unsecure":
                let site = try corral.site(named: arg1)
                try corral.setSecure(site, args[0] == "secure")
                print(corral.url(site).absoluteString)
            case "use":
                guard let v = arg1, corral.phpVersions()[v] != nil else { throw CorralError("Usage: corral use <installed version>") }
                corral.config.php = v
                try corral.apply()
            case "isolate":
                guard let v = arg1, corral.phpVersions()[v] != nil else { throw CorralError("Usage: corral isolate <installed version> [site]") }
                corral.config.isolated[try corral.site(named: arg2).name] = v
                try corral.apply()
            case "unisolate":
                corral.config.isolated[try corral.site(named: arg1).name] = nil
                try corral.apply()
            case "php:list":
                let installed = corral.phpVersions()
                let global = corral.globalPHP(installed)
                for v in Corral.sortVersions(installed.keys) { print("\(v == global ? "*" : " ") \(corral.phpFullVersion(v) ?? v)\t\(installed[v]!)") }
            case "php:install":
                guard let v = arg1 else { throw CorralError("Usage: corral php:install <\(Corral.phpChoices.joined(separator: "|"))>") }
                try corral.installPHP(v)
                print("Installed PHP \(v). Add \"\(corral.binDir)\" to your PATH to use php\(v.replacingOccurrences(of: ".", with: "")).")
            case "php:uninstall":
                guard let v = arg1 else { throw CorralError("Usage: corral php:uninstall <version>") }
                try corral.uninstallPHP(v)
            case "xdebug":
                var x = corral.config.xdebug, rest = Array(args.dropFirst())
                if let word = rest.first, word == "on" || word == "off" { x.enabled = word == "on"; rest.removeFirst() }
                guard rest.count % 2 == 0 else { throw CorralError("Each option needs a value. Run corral without arguments to see them.") }
                for pair in stride(from: 0, to: rest.count, by: 2) {
                    let value = rest[pair + 1]
                    switch rest[pair] {
                    case "--mode": x.mode = value
                    case "--host": x.clientHost = value
                    case "--port": x.clientPort = Int(value) ?? 0
                    case "--start": x.startWithRequest = value
                    default: throw CorralError("Unknown option \(rest[pair]). Use --mode, --host, --port or --start.")
                    }
                }
                if x != corral.config.xdebug { try corral.saveXdebug(x) }
                let versions = corral.debugVersions(corral.phpVersions())
                print("Xdebug \(x.enabled ? "on" : "off"): mode \(x.mode), client \(x.clientHost):\(x.clientPort), start with request \(x.startWithRequest)")
                if x.enabled { print("Debug pool for PHP \(versions.joined(separator: ", ")).") }
            case "open":
                NSWorkspace.shared.open(corral.url(try corral.site(named: arg1)))
            case "wp:setup":
                putBinFirst(corral)
                let (name, host) = try linkAndSecure(corral, arg1, cwd)
                for step in wpSetupSteps(name: name, host: host, dir: cwd) { try runLive(step) }
                print("https://\(host)/wp-admin  (user admin, password admin)")
                NSWorkspace.shared.open(URL(string: "https://\(host)/wp-admin")!)
            case "wp:import":
                guard let arg1 else { throw CorralError("Usage: corral wp:import <dump.sql or dump.sql.gz> [name]") }
                let dump = absolute(arg1, cwd)
                guard FileManager.default.fileExists(atPath: dump) else { throw CorralError("No file \(dump).") }
                guard FileManager.default.fileExists(atPath: cwd + "/wp-config.php") else {
                    throw CorralError("No wp-config.php in \(cwd). Run corral wp:setup first.")
                }
                putBinFirst(corral)
                let (_, host) = try linkAndSecure(corral, arg2, cwd)
                print("Importing \(dump)…")
                print(try Corral.wpImport(dump: dump, host: host) { try Corral.sh("/usr/bin/env", $0) })
                print("https://\(host)")
            case "tools":
                for tool in Corral.tools {
                    let have = corral.installedTool(tool)
                    print("\(tool.name)\t\(have?.version ?? "not installed")\t\(have.map { $0.updated ? "updated copy" : "bundled" } ?? "run: corral tools:update \(tool.name)")")
                }
            case "tools:update", "laravel:update":
                let wanted = args[0] == "laravel:update" ? "laravel" : arg1
                let list = Corral.tools.filter { wanted == nil || $0.name == wanted }
                guard !list.isEmpty else { throw CorralError("Unknown tool \(wanted ?? ""). Use composer, wp, or laravel.") }
                for tool in list {
                    if let v = try corral.updateTool(tool) { print("Updated \(tool.title) to \(v).") }
                    else { print("\(tool.title) is up to date (\(corral.installedTool(tool)?.version ?? "")).") }
                }
            case "new":
                guard let name = arg1, !name.hasPrefix("-") else { throw CorralError("Usage: corral new <name> [laravel new options]") }
                putBinFirst(corral)
                let dir = corral.config.parked.contains(cwd) ? cwd : corral.config.parked.first ?? cwd
                FileManager.default.changeCurrentDirectoryPath(dir)
                try runLive(newCommand(Array(args.dropFirst())))
                let host = try serveNewProject(corral, name: name, dir: dir)
                print("https://\(host)")
                NSWorkspace.shared.open(URL(string: "https://\(host)")!)
            case "mail":
                let list = MailMessage.all(in: URL(fileURLWithPath: corral.mailDir)).filter { arg1 == nil || $0.inbox == arg1 }
                if list.isEmpty { print(corral.config.mail ? "No mail." : "No mail. Turn on mail in Insights > Mail in the menu bar app.") }
                for (i, m) in list.enumerated() {
                    print("\(i + 1)\t\(m.date.formatted(date: .numeric, time: .shortened))\t\(m.inbox.isEmpty ? "-" : m.inbox)\t\(m.from)\t\(m.subject)")
                }
            case "mail:show", "mail:links":
                let list = MailMessage.all(in: URL(fileURLWithPath: corral.mailDir))
                guard let n = Int(arg1 ?? "1"), list.indices.contains(n - 1) else { throw CorralError("No message \(arg1 ?? "1"). Run corral mail to see the list.") }
                let raw = String(decoding: try Data(contentsOf: list[n - 1].url), as: UTF8.self)
                if args[0] == "mail:show" { print(raw) } else { MailMessage.links(raw).forEach { print($0) } }
            case "mail:clear":
                let list = MailMessage.all(in: URL(fileURLWithPath: corral.mailDir))
                for m in list { try FileManager.default.removeItem(at: m.url) }
                print("Deleted \(list.count) messages.")
            case "laravel:setup":
                putBinFirst(corral)
                let (name, host) = try linkAndSecure(corral, args.dropFirst().first { !$0.hasPrefix("--") }, cwd)
                try laravelSetup(name: name, host: host, dir: cwd, seed: args.contains("--seed"))
                print("https://\(host)")
                NSWorkspace.shared.open(URL(string: "https://\(host)")!)
            case "update":
                guard let update = try corral.availableUpdate() else { print("Corral is up to date."); return 0 }
                try corral.installUpdate(update)
                print("Installed Corral \(update.version). Quit and open Corral to use it.")
            case "trust":
                try corral.ensureCA()
                try corral.trustCA()
            default:
                print(usage)
                return args[0] == "help" ? 0 : 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("corral: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Asks on the terminal. --yes answers yes. No terminal (a script) answers no.
    static func confirm(_ question: String, _ flags: Set<String>) -> Bool {
        if flags.contains("--yes") { return true }
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        return ["y", "yes"].contains(readLine()?.lowercased() ?? "")
    }

    /// Setup commands run `php`, `composer`, and `wp` from PATH. Corral's own bin/ goes first, so they are the copies Corral manages.
    static func putBinFirst(_ corral: Corral) {
        setenv("PATH", corral.binDir + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"), 1)
    }

    /// Serves the current folder as <name>.<tld> over HTTPS. The name defaults to the folder name.
    static func linkAndSecure(_ corral: Corral, _ name: String?, _ cwd: String) throws -> (name: String, host: String) {
        let name = Corral.slug(name ?? (cwd as NSString).lastPathComponent)
        corral.config.links[name] = cwd
        try corral.apply()
        try corral.setSecure(try corral.site(named: name), true)
        return (name, "\(name).\(corral.config.tld)")
    }

    /// Site name -> database name: wp_crm.pigment becomes wp_crm_pigment. No dots or dashes, so no quoting problems.
    static func dbName(_ prefix: String, _ name: String) -> String {
        prefix + String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// The commands of `corral wp:setup`, in order. Each one runs through `env`, so `wp` and `php` come from PATH.
    /// Core and config are skipped when the folder already has them, so a rerun never overwrites a wp-config.php.
    static func wpSetupSteps(name: String, host: String, dir: String) -> [[String]] {
        let db = dbName("wp_", name)
        let has = { FileManager.default.fileExists(atPath: dir + "/" + $0) }
        var steps = [createDatabase(db)]
        if !has("wp-load.php") { steps.append(["wp", "core", "download", "--skip-content"]) }
        if !has("wp-config.php") {
            steps.append(["wp", "config", "create", "--dbname=\(db)", "--dbuser=root", "--dbpass=", "--dbhost=127.0.0.1", "--dbprefix=wp_", "--locale=en_US"])
        }
        steps.append(["wp", "core", "install", "--url=https://\(host)", "--title=\(name)", "--admin_user=admin", "--admin_password=admin",
                      "--admin_email=admin@\(host)", "--skip-email"])
        for key in ["WP_DEBUG", "WP_DEBUG_LOG", "WP_DEBUG_DISPLAY", "SCRIPT_DEBUG", "DISABLE_WP_CRON"] {
            steps.append(["wp", "config", "set", key, "true", "--raw"])
        }
        steps.append(["wp", "config", "set", "ENVIRONMENT", "DEV"])
        return steps
    }

    /// Creates a MySQL database with Corral's PHP (mysqli), so no `mysql` client is needed. It uses the same server
    /// as the configs that the setup writes: 127.0.0.1, user root, no password. db holds only letters, digits and _.
    static func createDatabase(_ db: String) -> [String] {
        ["php", "-r", """
        try { (new mysqli('127.0.0.1', 'root', ''))->query('CREATE DATABASE IF NOT EXISTS `\(db)`'); }
        catch (Throwable $e) { fwrite(STDERR, 'MySQL on 127.0.0.1 (user root): ' . $e->getMessage() . PHP_EOL); exit(1); }
        """]
    }

    /// The .env of a fresh clone: .env.example with the URL and a local MySQL database. Commented DB_ lines count.
    static func laravelEnv(_ example: String, host: String, db: String) -> String {
        let values = [("APP_URL", "https://\(host)"), ("DB_CONNECTION", "mysql"), ("DB_HOST", "127.0.0.1"), ("DB_PORT", "3306"),
                      ("DB_DATABASE", db), ("DB_USERNAME", "root"), ("DB_PASSWORD", "")]
        var text = example
        for (key, value) in values {
            text = text.replacingOccurrences(of: "\n# \(key)=", with: "\n\(key)=")
            text = Corral.setEnv(text, key, value)
        }
        return text
    }

    /// Set up a cloned Laravel project. An existing .env is never touched, so a project that already has a database
    /// (maybe a remote one) gets only `composer install` and the npm build, and no migrations.
    static func laravelSetup(name: String, host: String, dir: String, seed: Bool, runLive: ([String]) throws -> Void = CLI.runLive) throws {
        let fm = FileManager.default
        let has = { fm.fileExists(atPath: dir + "/" + $0) }
        if !has("vendor/autoload.php") { try runLive(["composer", "install"]) }
        if has(".env") {
            print("Kept the existing .env. Skipped the key, the database, and the migrations.")
        } else {
            guard let example = try? String(contentsOfFile: dir + "/.env.example", encoding: .utf8) else {
                throw CorralError("No .env and no .env.example in \(dir).")
            }
            let db = dbName("", name)
            try laravelEnv(example, host: host, db: db).write(toFile: dir + "/.env", atomically: true, encoding: .utf8)
            try runLive(["php", "artisan", "key:generate"])
            try runLive(createDatabase(db))
            try runLive(["php", "artisan", "migrate"] + (seed ? ["--seed"] : []))
        }
        if has("package.json") {
            try runLive(["npm", "install"])
            try runLive(["npm", "run", "build"])
        }
    }

    /// The installer command for `corral new`. Laravel Boost is an AI add-on, so it stays out unless asked for.
    static func newCommand(_ args: [String]) -> [String] {
        ["laravel", "new"] + args + (args.contains("--boost") || args.contains("--no-boost") ? [] : ["--no-boost"])
    }

    /// Serves a project that `laravel new` made in dir: HTTPS, and APP_URL in .env. A parked folder needs no link.
    static func serveNewProject(_ corral: Corral, name: String, dir: String) throws -> String {
        let path = dir + "/" + name
        let host: String
        if corral.config.parked.contains(dir) {
            let site = try corral.site(named: name)
            try corral.setSecure(site, true)
            host = corral.host(site)
        } else {
            host = try linkAndSecure(corral, name, path).host
        }
        if let env = try? String(contentsOfFile: path + "/.env", encoding: .utf8) {
            try Corral.setEnv(env, "APP_URL", "https://\(host)").write(toFile: path + "/.env", atomically: true, encoding: .utf8)
        }
        return host
    }

    /// `corral run [--name n] [--port p] <command…>`. The options end at the first word that is not an option.
    static func runOptions(_ args: [String], cwd: String) throws -> (name: String, port: Int?, command: [String]) {
        var rest = args[...], name = (cwd as NSString).lastPathComponent, port: Int?
        while let flag = rest.first, flag == "--name" || flag == "--port" {
            guard rest.count > 1 else { throw CorralError("\(flag) needs a value.") }
            let value = rest[rest.startIndex + 1]
            if flag == "--name" {
                name = value
            } else {
                guard let p = Int(value), (1...65535).contains(p) else { throw CorralError("Bad port: \(value)") }
                port = p
            }
            rest = rest.dropFirst(2)
        }
        guard !rest.isEmpty, !Corral.slug(name).isEmpty else { throw CorralError("Usage: corral run [--name <name>] [--port <port>] <command>") }
        return (Corral.slug(name), port, Array(rest))
    }

    /// A port on 127.0.0.1 that nothing listens on now. The kernel picks it.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard fd >= 0, ok else { throw CorralError("Could not find a free port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// The command that `corral run` started. A SIGTERM to Corral goes on to it.
    nonisolated(unsafe) static var child: pid_t = 0

    /// Serves the command's port as https://<name>.<tld> while the command runs, then removes the proxy again.
    /// An existing proxy or site with the same name comes back when the command stops.
    // ponytail: a SIGKILL to Corral leaves the proxy in config.json. `corral unproxy <name>` removes it.
    static func runDevServer(_ corral: Corral, name: String, port: Int?, command: [String]) throws -> Int32 {
        let port = try port ?? freePort()
        let upstream = URL(string: "http://127.0.0.1:\(port)")!
        let before = (proxy: corral.config.proxies[name], secured: corral.config.secured.contains(name))
        corral.config.proxies[name] = upstream.absoluteString
        defer {
            // Read config.json again: other commands may have changed it while the server ran.
            let now = Corral()
            now.config.proxies[name] = before.proxy
            if !before.secured { now.config.secured.remove(name) }
            do { try now.apply() } catch {
                FileHandle.standardError.write(Data("corral: could not remove the proxy \(name): \(error.localizedDescription)\n".utf8))
            }
        }
        let site = Site(name: name, proxy: upstream)
        try corral.setSecure(site, true)
        if !corral.isRunning { try corral.start() }
        print("\(corral.url(site).absoluteString) -> \(upstream.absoluteString)\n")

        // Ctrl-C and a closed terminal reach the command too. Corral waits for it to stop, then cleans up.
        signal(SIGINT) { _ in }
        signal(SIGHUP) { _ in }
        signal(SIGTERM) { _ in if CLI.child > 0 { kill(CLI.child, SIGTERM) } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = command
        p.environment = ProcessInfo.processInfo.environment.merging(["PORT": String(port)]) { $1 }
        var status: Int32 = 127
        do {
            try p.run()
            child = p.processIdentifier
            p.waitUntilExit()
            status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data("corral: could not run \(command[0]): \(error.localizedDescription)\n".utf8))
        }
        return status
    }

    /// Runs a command in the current folder with the terminal attached, so the user sees its output.
    static func runLive(_ argv: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CorralError("\(argv.prefix(3).joined(separator: " ")) failed (exit \(p.terminationStatus))") }
    }

    static func absolute(_ path: String, _ cwd: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
    }
}
