import AppKit

enum CLI {
    static let usage = """
    Corral: local PHP sites on .<tld>, Herd-style.

      install | uninstall          one-time system setup (resolver, loopback alias, pf 80/443 redirect)
      takeover | handback          send .test to Corral, or give it back to Herd
      import:herd                  copy Herd's parked folders, links, secured sites and global PHP
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
      php:list                     installed PHP versions
      php:install <ver>            download a static PHP build, for example 8.4
      php:uninstall <ver>          remove a PHP version that Corral installed
      open [site]
      trust                        trust the local CA in your login keychain

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
                try corral.runAsAdmin(corral.installScript())
                print("Installed. *.\(corral.config.tld) -> \(Corral.loopback), ports 80/443 -> \(Corral.httpPort)/\(Corral.httpsPort).")
            case "uninstall":
                corral.stop()
                try corral.runAsAdmin(corral.uninstallScript())
                print("System changes removed. Config left in \(corral.home).")
            case "start", "restart":
                if args[0] == "restart" { corral.stop() }
                try corral.start()
                if !corral.isInstalled { print("Running, but run `corral install` once so *.\(corral.config.tld) resolves.") }
                fallthrough
            case "status":
                for (name, up) in corral.status() { print("\(up ? "●" : "○") \(name)") }
                print(".\(Corral.sharedTLD) goes to \(corral.ownsTest ? "Corral" : "Herd (or nothing)")")
            case "import:herd":
                let r = try corral.importHerd()
                print("Parked folders added: \(r.parked.isEmpty ? "none" : r.parked.joined(separator: ", "))")
                print("Links added: \(r.links.isEmpty ? "none" : r.links.joined(separator: ", "))")
                print("Sites secured: \(r.secured.count)\(r.secured.isEmpty ? "" : " (\(r.secured.joined(separator: ", ")))")")
                if !r.skipped.isEmpty { print("Certificates skipped, no matching site: \(r.skipped.joined(separator: ", "))") }
                print("Global PHP: \(r.php ?? "not found in Herd")")
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
                for v in Corral.sortVersions(installed.keys) { print("\(v == global ? "*" : " ") \(v)\t\(installed[v]!)") }
            case "php:install":
                guard let v = arg1 else { throw CorralError("Usage: corral php:install <\(Corral.phpChoices.joined(separator: "|"))>") }
                try corral.installPHP(v)
                print("Installed PHP \(v). Add \"\(corral.binDir)\" to your PATH to use php\(v.replacingOccurrences(of: ".", with: "")).")
            case "php:uninstall":
                guard let v = arg1 else { throw CorralError("Usage: corral php:uninstall <version>") }
                try corral.uninstallPHP(v)
            case "open":
                NSWorkspace.shared.open(corral.url(try corral.site(named: arg1)))
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

    static func absolute(_ path: String, _ cwd: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
    }
}
