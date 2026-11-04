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
      sites                        list sites
      secure [site] | unsecure [site]
      secured                      list secured sites with the expiry date of each certificate
      use <ver>                    set the global PHP version
      isolate <ver> [site] | unisolate [site]
      php:list                     installed PHP versions (Corral builds only)
      php:install <ver>            download a static PHP build, for example 8.4
      php:uninstall <ver>          remove a PHP version that Corral installed
      wp:setup [name]              set up WordPress in the current folder: database, core, config, HTTPS,
                                   debug settings. Needs `wp` and `mysql` in PATH.
      laravel:setup [name] [--seed]  set up a cloned Laravel project: composer, .env, key, database,
                                   migrations, npm build, HTTPS. Needs `composer` in PATH.
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
            case "open":
                NSWorkspace.shared.open(corral.url(try corral.site(named: arg1)))
            case "wp:setup":
                let (name, host) = try linkAndSecure(corral, arg1, cwd)
                for step in wpSetupSteps(name: name, host: host, dir: cwd) { try runLive(step) }
                print("https://\(host)/wp-admin  (user admin, password admin)")
                NSWorkspace.shared.open(URL(string: "https://\(host)/wp-admin")!)
            case "laravel:setup":
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

    /// The commands of `corral wp:setup`, in order. Each one runs through `env`, so `wp` and `mysql` come from PATH.
    /// Core and config are skipped when the folder already has them, so a rerun never overwrites a wp-config.php.
    static func wpSetupSteps(name: String, host: String, dir: String) -> [[String]] {
        let db = dbName("wp_", name)
        let has = { FileManager.default.fileExists(atPath: dir + "/" + $0) }
        var steps = [["mysql", "-u", "root", "-e", "CREATE DATABASE IF NOT EXISTS `\(db)`"]]
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
            try runLive(["mysql", "-u", "root", "-e", "CREATE DATABASE IF NOT EXISTS `\(db)`"])
            try runLive(["php", "artisan", "migrate"] + (seed ? ["--seed"] : []))
        }
        if has("package.json") {
            try runLive(["npm", "install"])
            try runLive(["npm", "run", "build"])
        }
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
