import Foundation
import SwiftUI
import Testing
@testable import Corral

@Test func sitesConfigAndCertificates() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: tmp + "/parked/Blog/public", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tmp + "/parked/API Docs", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tmp + "/parked/.hidden", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tmp + "/elsewhere", withIntermediateDirectories: true)

    let c = Corral(home: tmp + "/home")
    c.config.tld = "internal"
    c.config.aliases = ["test"]
    c.config.parked = [tmp + "/parked"]
    c.config.links = ["shop": tmp + "/elsewhere", "blog": tmp + "/elsewhere"] // link overrides parked "blog"
    c.config.secured = ["shop"]
    c.config.isolated = ["shop": "8.4"]

    let sites = c.sites()
    #expect(sites.map(\.name) == ["api-docs", "blog", "shop"])
    #expect(Corral.slug("crm.pigment") == "crm.pigment") // same host as Herd and Valet
    #expect(Corral.slug(".hidden.") == "hidden")
    #expect(sites.first { $0.name == "blog" }?.path == tmp + "/elsewhere")

    // PHP resolution: isolated version wins only if installed; otherwise the newest is global.
    let installed = ["8.3": "/x", "8.4": "/y", "8.10": "/z"]
    #expect(c.globalPHP(installed) == "8.10")
    let shop = sites.first { $0.name == "shop" }!
    #expect(c.php(for: shop, installed) == "8.4")
    #expect(c.php(for: shop, ["8.3": "/x"]) == "8.3")

    let parkedOnly = Corral(home: tmp + "/home2")
    parkedOnly.config.parked = [tmp + "/parked"]
    let blog = parkedOnly.sites().first { $0.name == "blog" }!
    #expect(blog.docroot == tmp + "/parked/Blog/public")

    let conf = c.nginxConf(sites: sites, installed: installed)
    #expect(conf.contains("server_name shop.internal *.shop.internal shop.test *.shop.test;"))
    #expect(conf.contains("listen 127.0.0.1:8543 ssl;"))
    #expect(conf.contains("return 301 https://$host$request_uri;"))
    #expect(conf.contains("port_in_redirect off;"))
    #expect(conf.contains("php8.4.sock"))
    #expect(conf.contains("root \"\(tmp)/parked/API Docs\";"))
    #expect(conf.components(separatedBy: "listen 127.0.0.1:8543").count == 2) // only shop is secured

    // CA + leaf cert chain verifies, with the wildcard SAN.
    #expect(try c.ensureCA() == true)
    #expect(try c.ensureCA() == false)
    try c.makeCert(["shop.internal", "shop.test"])
    let verify = try c.sh("/usr/bin/openssl", ["verify", "-CAfile", c.caPem, c.certs + "/shop.internal.crt"])
    #expect(verify.contains("OK"))
    let text = try c.sh("/usr/bin/openssl", ["x509", "-noout", "-text", "-in", c.certs + "/shop.internal.crt"])
    #expect(text.contains("DNS:*.shop.internal"))
    #expect(text.contains("DNS:shop.test") && text.contains("DNS:*.shop.test"))

    #expect(try c.installScript().contains("port 53535"))
}

@Test func driversAndOverrides() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    for dir in ["wp", "craft/web", "custom/dist", "broken"] { try fm.createDirectory(atPath: "\(tmp)/\(dir)", withIntermediateDirectories: true) }
    fm.createFile(atPath: tmp + "/wp/wp-load.php", contents: nil)
    fm.createFile(atPath: tmp + "/custom/.corral.json", contents: Data(#"{"root": "dist", "nginx": "add_header X-Test yes;"}"#.utf8))
    fm.createFile(atPath: tmp + "/broken/.corral.json", contents: Data("{oops".utf8))

    let wp = Site(name: "wp", path: tmp + "/wp")
    let craft = Site(name: "craft", path: tmp + "/craft")
    let custom = Site(name: "custom", path: tmp + "/custom")
    #expect(wp.isWordPress && !craft.isWordPress)
    #expect(craft.docroot == tmp + "/craft/web")
    #expect(custom.docroot == tmp + "/custom/dist")
    #expect(Site(name: "broken", path: tmp + "/broken").overridesError != nil)

    let c = Corral(home: tmp + "/home")
    let conf = c.nginxConf(sites: [wp, custom], installed: ["8.4": "/x"])
    #expect(conf.components(separatedBy: "rewrite ^(/[^/]+)?(/wp-.*) $2 last;").count == 2) // only the WordPress site
    #expect(conf.contains("add_header X-Test yes;"))

    c.config.parked = [tmp]
    #expect(throws: CorralError.self) { try c.writeConfigs() }
}

@Test func proxiesAndConfigLoading() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

    // A config.json from an older version (no "proxies" key) keeps its settings.
    try Data(#"{"tld": "test", "parked": ["/x"], "links": {}, "secured": [], "isolated": {}}"#.utf8)
        .write(to: URL(fileURLWithPath: tmp + "/config.json"))
    let c = Corral(home: tmp)
    #expect(c.loadError == nil && c.config.tld == "test" && c.config.parked == ["/x"] && c.config.proxies.isEmpty)

    c.config.proxies = ["shop": "https://shop.localhost:1355", "api": "http://127.0.0.1:3000"]
    let sites = c.sites()
    let conf = c.nginxConf(sites: sites, installed: [:])
    #expect(conf.contains("proxy_pass https://127.0.0.1:1355;"))
    #expect(conf.contains("proxy_set_header Host \"shop.localhost:1355\";"))
    #expect(conf.contains("proxy_ssl_name shop.localhost;"))
    #expect(conf.contains("proxy_pass http://127.0.0.1:3000;"))
    #expect(conf.contains("map $http_upgrade $connection_upgrade"))
    #expect(!conf.contains("fastcgi_pass")) // proxies never touch PHP

    // A broken config.json is never overwritten.
    try Data("{broken".utf8).write(to: URL(fileURLWithPath: tmp + "/config.json"))
    let broken = Corral(home: tmp)
    #expect(broken.loadError != nil)
    #expect(throws: CorralError.self) { try broken.save() }
    #expect(try String(contentsOfFile: tmp + "/config.json", encoding: .utf8) == "{broken")
}

@Test func managedPhpAndShims() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let c = Corral(home: tmp)
    try c.mkdirs(c.phpDir + "/8.4")
    for bin in ["php", "php-fpm"] {
        FileManager.default.createFile(atPath: "\(c.phpDir)/8.4/\(bin)", contents: Data("#!/bin/sh\n".utf8))
        chmod("\(c.phpDir)/8.4/\(bin)", 0o755)
    }
    let installed = c.phpVersions()
    let fpm = try #require(installed["8.4"])
    #expect(Set(installed.keys) == ["8.4"]) // Homebrew PHP on this Mac does not count
    #expect(c.cliPath(fpm) == c.phpDir + "/8.4/php")
    #expect(c.iniArgs(fpm) == ["-c", c.phpDir + "/8.4/php.ini"])
    try "8.4.27\n".write(toFile: c.phpDir + "/8.4/VERSION", atomically: true, encoding: .utf8)
    #expect(c.phpFullVersion("8.4") == "8.4.27")

    c.config.php = "8.4"
    try c.writeShims(["8.4": fpm])
    let shim = try String(contentsOfFile: c.binDir + "/php", encoding: .utf8)
    // The -d MySQL socket arguments in between depend on this machine's /tmp.
    #expect(shim.hasPrefix("#!/bin/sh\nexec \"\(c.phpDir)/8.4/php\" \"-c\" \"\(c.phpDir)/8.4/php.ini\" "))
    #expect(shim.hasSuffix(" \"$@\"\n"))
    #expect(FileManager.default.isExecutableFile(atPath: c.binDir + "/php84"))

    // Composer, WP-CLI, and the Laravel installer run on the global PHP. An updated copy in tools/ wins over the bundled one.
    let phars = tmp + "/phar"
    try c.mkdirs(phars)
    try c.writeShims(["8.4": fpm], pharDir: phars)
    let wp = try String(contentsOfFile: c.binDir + "/wp", encoding: .utf8)
    #expect(wp.hasPrefix("#!/bin/sh\np=\"\(c.toolsDir)/wp-cli.phar\"\n[ -f \"$p\" ] || p=\"\(phars)/wp-cli.phar\"\n"))
    #expect(wp.contains("Run: corral tools:update wp") && wp.contains("\"-d\" \"error_reporting=8191\" \"$p\" \"$@\"\n"))
    #expect(wp.contains("exec \"\(c.phpDir)/8.4/php\" "))
    for name in ["composer", "wp", "laravel"] { #expect(FileManager.default.isExecutableFile(atPath: c.binDir + "/" + name)) }
    // Without the phar, the shim says what to run.
    let missing = try Process.run(URL(fileURLWithPath: c.binDir + "/laravel"), arguments: [])
    missing.waitUntilExit()
    #expect(missing.terminationStatus == 1)
    // No bundled phars: the shims look only in tools/.
    try c.writeShims(["8.4": fpm], pharDir: nil)
    #expect(!(try String(contentsOfFile: c.binDir + "/wp", encoding: .utf8)).contains(phars))
}

@Test func toolReleasesAndInstall() throws {
    // Composer: the newest stable version and the checksum file of its phar.
    let composer = try Corral.composerRelease(#"{"stable": [{"path": "/download/2.11.1/composer.phar", "version": "2.11.1"}, {"path": "/download/2.9.0/composer.phar", "version": "2.9.0"}]}"#) {
        #expect($0 == "https://getcomposer.org/download/2.11.1/composer.phar.sha256sum")
        return "ab"
    }
    #expect(composer == Corral.ToolRelease(version: "2.11.1", url: "https://getcomposer.org/download/2.11.1/composer.phar", sha256: "ab"))
    let wp = try Corral.wpRelease(#"{"tag_name": "v2.12.0"}"#) { _ in "cd" }
    #expect(wp.url == "https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar" && wp.version == "2.12.0")
    #expect(throws: CorralError.self) { try Corral.wpRelease(#"{"tag_name": "nightly"}"#) { _ in "" } }
    let laravel = try Corral.laravelRelease(#"{"laravel": {"version": "5.32.0", "file": "laravel.phar", "sha256": "ef"}}"#, base: "https://x/tools")
    #expect(laravel == Corral.ToolRelease(version: "5.32.0", url: "https://x/tools/laravel.phar", sha256: "ef"))
    #expect(throws: CorralError.self) { try Corral.laravelRelease(#"{"laravel": {"version": "1", "file": "../evil", "sha256": "ef"}}"#, base: "https://x") }

    // Install: the checksum must match. The tool then reports the new version and counts as an updated copy.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp + "/src", withIntermediateDirectories: true)
    try "phar bytes".write(toFile: tmp + "/src/laravel.phar", atomically: true, encoding: .utf8)
    let sha = try Corral.sh("/usr/bin/shasum", ["-a", "256", tmp + "/src/laravel.phar"]).split(separator: " ").first.map(String.init) ?? ""
    let c = Corral(home: tmp + "/home")
    let tool = try #require(Corral.tools.first { $0.name == "laravel" })
    #expect(c.installedTool(tool) == nil || c.installedTool(tool)?.updated == false) // bundled copy, if any
    #expect(throws: CorralError.self) { try c.installTool(tool, .init(version: "9.9.9", url: "file://" + tmp + "/src/laravel.phar", sha256: "00")) }
    #expect(!FileManager.default.fileExists(atPath: c.toolsDir + "/laravel.phar"))
    #expect(!FileManager.default.fileExists(atPath: c.toolsDir + "/laravel.phar.download"))
    try c.installTool(tool, .init(version: "9.9.9", url: "file://" + tmp + "/src/laravel.phar", sha256: sha))
    #expect(try String(contentsOfFile: c.toolsDir + "/laravel.phar", encoding: .utf8) == "phar bytes")
    #expect(c.installedTool(tool)?.version == "9.9.9" && c.installedTool(tool)?.updated == true)
    let composerTool = try #require(Corral.tools.first { $0.name == "composer" })
    try c.installTool(composerTool, .init(version: "2.0.0", url: "file://" + tmp + "/src/laravel.phar", sha256: sha))
    #expect(Corral.toolVersions(in: c.toolsDir) == ["laravel": "9.9.9", "composer": "2.0.0"]) // one versions.json for all tools
}

@Test func mysqlSocketDetection() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    #expect(Corral.mysqlSocket(in: tmp) == nil) // no MySQL
    for f in ["mysqlx.sock", "mysql-3307.sock", "mysql_3306.sock"] { fm.createFile(atPath: "\(tmp)/\(f)", contents: nil) }
    #expect(Corral.mysqlSocket(in: tmp) == tmp + "/mysql_3306.sock") // 3306 wins, X protocol ignored
    fm.createFile(atPath: tmp + "/mysql.sock", contents: nil)
    #expect(Corral.mysqlSocket(in: tmp) == nil) // PHP's default already works
}

@Test func sharingTestWithHerd() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    try "nameserver 127.0.0.1".write(toFile: tmp + "/herd", atomically: true, encoding: .utf8)
    try "nameserver 127.0.0.1\nport 53535\n".write(toFile: tmp + "/corral", atomically: true, encoding: .utf8)
    #expect(!Corral.resolverIsCorral(tmp + "/herd"))   // Herd's file does not count as installed
    #expect(Corral.resolverIsCorral(tmp + "/corral"))
    #expect(!Corral.resolverIsCorral(tmp + "/missing"))

    let c = Corral(home: tmp + "/home")
    #expect(c.tlds == ["test"])
    c.config.tld = "internal"
    c.config.aliases = ["test"]
    #expect(c.tlds == ["internal", "test"])
    let take = c.takeoverScript(), back = c.handbackScript()
    #expect(take.contains("cp -p /etc/resolver/test \"\(Corral.resolverBackup)\""))   // keeps Herd's file
    #expect(back.contains("mv \"\(Corral.resolverBackup)\" /etc/resolver/test"))   // and restores it
    #expect(c.uninstallScript().hasPrefix(back))                                // uninstall hands .test back
    #expect(!c.uninstallScript().contains("rm -f /Library/LaunchDaemons/dev.corral.network.plist /etc/resolver"))

    c.config.tld = "test"
    #expect(c.tlds == ["test"])                                 // no duplicate
}

@Test func importFromHerd() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    let herd = tmp + "/Herd", valet = herd + "/config/valet"
    for d in ["projects/shop/public", "projects/rfsu", "other/blog", "\(valet)/Sites", "\(valet)/Certificates"] {
        try fm.createDirectory(atPath: d.hasPrefix("/") ? d : "\(tmp)/\(d)", withIntermediateDirectories: true)
    }
    let config = ["tld": "test", "paths": ["\(valet)/Sites", "\(tmp)/projects/", "\(tmp)/missing"]] as [String: Any]
    try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: valet + "/config.json"))
    try fm.createSymbolicLink(atPath: valet + "/Sites/rfsudev", withDestinationPath: tmp + "/projects/rfsu")   // alias
    try fm.createSymbolicLink(atPath: valet + "/Sites/blog", withDestinationPath: tmp + "/other/blog")        // outside parked
    try fm.createSymbolicLink(atPath: valet + "/Sites/shop", withDestinationPath: tmp + "/projects/shop")     // same as parked
    try fm.createSymbolicLink(atPath: valet + "/Sites/dead", withDestinationPath: tmp + "/nowhere")
    for f in ["shop.test.crt", "rfsudev.test.crt", "gone.test.crt", "shop.test.key"] { fm.createFile(atPath: "\(valet)/Certificates/\(f)", contents: nil) }
    try fm.createSymbolicLink(atPath: herd + "/herd.sock", withDestinationPath: herd + "/herd84.sock")

    try fm.createDirectory(atPath: valet + "/Nginx", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: herd + "/config/php/84", withIntermediateDirectories: true)
    try "location / { proxy_pass http://127.0.0.1:3000; }".write(toFile: valet + "/Nginx/api.test", atomically: true, encoding: .utf8)
    try "fastcgi_pass \"unix:/x/herd84.sock\";".write(toFile: valet + "/Nginx/rfsudev.test", atomically: true, encoding: .utf8)
    try "# ISOLATED_PHP_VERSION=php@8.2\n".write(toFile: valet + "/Nginx/blog.test", atomically: true, encoding: .utf8)
    try "upload_max_filesize=64M\nmemory_limit = 1024M\nextension=/Herd/herd-84.so\ncurl.cainfo=/x/cacert.pem\n;max_input_vars=9\n"
        .write(toFile: herd + "/config/php/84/php.ini", atomically: true, encoding: .utf8)
    fm.createFile(atPath: tmp + "/projects/shop/.nvmrc", contents: Data("20\n".utf8))

    let c = Corral(home: tmp + "/home")
    c.config.parked = []
    try c.mkdirs(c.phpDir + "/8.4")  // PHP 8.4 is "installed", so the import downloads nothing
    for bin in ["php", "php-fpm"] { fm.createFile(atPath: "\(c.phpDir)/8.4/\(bin)", contents: Data("#!/bin/sh\n".utf8)); chmod("\(c.phpDir)/8.4/\(bin)", 0o755) }
    try Corral.defaultPhpIni.write(toFile: c.phpDir + "/8.4/php.ini", atomically: true, encoding: .utf8)

    // A dry run shows the plan and changes nothing.
    let before = c.config
    let plan = try c.importHerd(from: herd, trust: false, dryRun: true)
    #expect(c.config == before && !fm.fileExists(atPath: c.certs))
    #expect(plan.isolated == ["rfsudev": "8.4", "blog": "8.2"] && plan.installs == ["8.2"])
    #expect(plan.proxies == ["api": "http://127.0.0.1:3000"])
    #expect(plan.ini == ["8.4": ["upload_max_filesize": "64M"]])  // Herd-only lines and unchanged values left out
    #expect(plan.node == ["shop"])
    #expect(plan.summary.contains("PHP to download: 8.2"))

    try fm.removeItem(atPath: valet + "/Nginx/blog.test")          // the real run must not download PHP 8.2
    let r = try c.importHerd(from: herd, trust: false)
    #expect(c.config.isolated == ["rfsudev": "8.4"] && c.config.proxies == ["api": "http://127.0.0.1:3000"])
    #expect(Corral.iniValue(try String(contentsOfFile: c.phpDir + "/8.4/php.ini", encoding: .utf8), "upload_max_filesize") == "64M")
    #expect(r.parked == [tmp + "/projects"])                  // trailing slash removed, Sites and missing folder ignored
    #expect(r.links == ["blog", "rfsudev"])                   // shop is already parked, dead link ignored
    #expect(c.config.links["rfsudev"] == tmp + "/projects/rfsu")
    #expect(r.secured == ["rfsudev", "shop"])
    #expect(r.skipped == ["gone"])
    #expect(r.php == "8.4" && c.config.php == "8.4")
    #expect(fm.fileExists(atPath: c.certs + "/shop.test.crt"))

    let again = try c.importHerd(from: herd, trust: false)    // a second run changes nothing
    #expect(again.parked.isEmpty && again.links.isEmpty && again.secured.isEmpty && again.isolated.isEmpty && again.ini.isEmpty)

    #expect(Corral.diagnose(status: 500, "require(/x/vendor/autoload.php): Failed to open stream") == "missing Composer packages: run composer install")
    #expect(Corral.diagnose(status: 500, "SQLSTATE[HY000] [1045] Access denied for user 'root'") == "wrong database user or password")
    #expect(Corral.diagnose(status: 500, "") == "HTTP 500")
    #expect(Corral.diagnose(status: 0, "") == "no response")
    #expect(Corral.diagnose(status: 200, "<html>") == nil)
}

@Test func installPhpFromManifest() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    let src = tmp + "/release", stage = tmp + "/stage"
    for d in [src, stage] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    for bin in ["php", "php-fpm"] { fm.createFile(atPath: "\(stage)/\(bin)", contents: Data("#!/bin/sh\necho \(bin)\n".utf8)); chmod("\(stage)/\(bin)", 0o755) }

    let c = Corral(home: tmp + "/home")
    let file = "php-8.4.99-macos-aarch64.tar.gz"
    try c.sh("/usr/bin/tar", ["czf", "\(src)/\(file)", "-C", stage, "php", "php-fpm"])
    let sha = try c.sh("/usr/bin/shasum", ["-a", "256", "\(src)/\(file)"]).split(separator: " ")[0]
    func manifest(_ digest: Substring) throws {
        try Data(#"{"8.4": {"version": "8.4.99", "file": "\#(file)", "sha256": "\#(digest)"}}"#.utf8)
            .write(to: URL(fileURLWithPath: src + "/manifest.json"))
    }
    c.phpSource = "file://" + src

    try manifest("0000" + sha.dropFirst(4))                 // wrong checksum: nothing gets installed
    #expect(throws: CorralError.self) { try c.installPHP("8.4") }
    #expect(!fm.fileExists(atPath: c.phpDir + "/8.4"))

    try manifest(sha)
    try c.installPHP("8.4")
    #expect(fm.isExecutableFile(atPath: c.phpDir + "/8.4/php-fpm"))
    #expect(fm.fileExists(atPath: c.phpDir + "/8.4/php.ini"))
    #expect(c.phpVersions()["8.4"] == c.phpDir + "/8.4/php-fpm")

    #expect(throws: CorralError.self) { try c.installPHP("7.4") } // not in the manifest
}

@Test func certificateRenewal() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: tmp + "/sites/shop", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tmp + "/sites/blog", withIntermediateDirectories: true)
    let c = Corral(home: tmp + "/home")
    c.config.parked = [tmp + "/sites"]
    c.config.secured = ["shop", "blog"]
    try c.ensureCA()
    let shop = c.sites().first { $0.name == "shop" }!, blog = c.sites().first { $0.name == "blog" }!

    try c.makeCert(c.hostnames(shop), days: 5)     // expires soon
    try c.makeCert(c.hostnames(blog))              // 397 days
    #expect(c.certNeedsRenewal(c.certPath(shop)))
    #expect(!c.certNeedsRenewal(c.certPath(blog)))
    #expect(c.certNeedsRenewal(tmp + "/missing.crt"))
    let before = c.certExpiry(c.certPath(blog))

    #expect(try c.renewCertificates() == ["shop"])  // only the one that is due
    #expect(!c.certNeedsRenewal(c.certPath(shop)))
    #expect(c.certExpiry(c.certPath(blog)) == before)
    #expect(try c.renewCertificates().isEmpty)     // nothing left to do

    try fm.removeItem(atPath: c.certPath(blog))     // a lost certificate comes back too
    #expect(try c.renewCertificates() == ["blog"])
}

@Test func tldsAndSiteDomains() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: tmp + "/sites/shop", withIntermediateDirectories: true)
    fm.createFile(atPath: tmp + "/sites/shop/.corral.json", contents: Data(#"{"domains": ["Shop.local"]}"#.utf8))

    // Old configs keep their names: .internal plus .test. New ones serve .test only.
    func load(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    #expect(try load(#"{"tld": "internal"}"#).aliases == ["test"])
    #expect(try load(#"{"tld": "test"}"#).aliases == [])
    #expect(try load(#"{"tld": "internal", "aliases": []}"#).aliases == [])
    #expect(Config().tld == "test" && Config().aliases.isEmpty)

    let c = Corral(home: tmp + "/home")
    c.config.parked = [tmp + "/sites"]
    let shop = c.sites()[0]
    #expect(c.hostnames(shop) == ["shop.test", "shop.local"])
    #expect(c.dnsNames(c.sites()) == ["test", "shop.local"])
    #expect(c.resolverTLDs(c.sites()) == ["local", "test"])    // .test is the main TLD here
    #expect(c.dnsmasqConf(c.sites()).contains("address=/test/shop.local/127.0.0.2\n"))
    #expect(c.nginxConf(sites: c.sites(), installed: [:]).contains("server_name shop.test *.shop.test shop.local *.shop.local;"))
    let install = try c.installScript()
    #expect(install.contains("> /etc/resolver/local") && install.contains("cp -p /etc/resolver/test")) // takes .test over, keeps Herd's file
    #expect(c.uninstallScript().contains("for f in /etc/resolver/*"))

    c.config.tld = "internal"
    c.config.aliases = ["test"]
    #expect(c.resolverTLDs(c.sites()) == ["internal", "local"]) // .test as an alias stays with takeover
    #expect(try !c.installScript().contains("cp -p /etc/resolver/test"))

    // A name change makes a new certificate, even when the old one is still valid.
    c.config.secured = ["shop"]
    try c.ensureCA()
    try c.makeCert(c.hostnames(shop))
    #expect(!c.certNamesChanged(shop))
    #expect(try c.renewCertificates().isEmpty)
    c.config.aliases = ["test", "dev"]
    #expect(c.certNamesChanged(shop))
    #expect(try c.renewCertificates() == ["shop"])
    let text = try c.sh("/usr/bin/openssl", ["x509", "-noout", "-text", "-in", c.certPath(shop)])
    #expect(text.contains("DNS:*.shop.dev") && text.contains("DNS:shop.local"))
}

@Test func phpSettings() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default

    let ini = "; memory_limit = 1M\nmemory_limit = 128M\nmemory_limit=256M\ndate.timezone = \"UTC\"\n"
    #expect(Corral.iniValue(ini, "memory_limit") == "256M")       // the last line wins, comments do not count
    #expect(Corral.iniValue(ini, "date.timezone") == "UTC")
    #expect(Corral.iniValue(ini, "max_input_vars") == nil)
    let changed = Corral.setIni(Corral.setIni(ini, "memory_limit", "-1"), "max_input_vars", "5000")
    #expect(changed == "; memory_limit = 1M\nmemory_limit = 128M\nmemory_limit = -1\ndate.timezone = \"UTC\"\nmax_input_vars = 5000\n")

    // Fake PHP: the CLI complains about "bad" values, php-fpm -t accepts everything.
    let c = Corral(home: tmp + "/home")
    try c.mkdirs(c.phpDir + "/8.4")
    try "#!/bin/sh\ngrep -q bad \"$2\" && echo 'Warning: Invalid quantity'\nexit 0\n".write(toFile: c.phpDir + "/8.4/php", atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(toFile: c.phpDir + "/8.4/php-fpm", atomically: true, encoding: .utf8)
    for bin in ["php", "php-fpm"] { chmod("\(c.phpDir)/8.4/\(bin)", 0o755) }
    try ini.write(toFile: c.phpDir + "/8.4/php.ini", atomically: true, encoding: .utf8)

    #expect(throws: CorralError.self) { try c.savePHPSettings("8.4", ini: ["memory_limit": "bad"], pool: FpmPool()) }
    #expect(try String(contentsOfFile: c.phpDir + "/8.4/php.ini", encoding: .utf8) == ini) // nothing changed

    let pool = FpmPool(pm: "ondemand", maxChildren: 8, requestTerminateTimeout: 60, slowlogTimeout: 5)
    try c.savePHPSettings("8.4", ini: ["memory_limit": "512M", "date.timezone": "UTC"], pool: pool)
    #expect(Corral.iniValue(try String(contentsOfFile: c.phpDir + "/8.4/php.ini", encoding: .utf8), "memory_limit") == "512M")
    #expect(c.config.fpm["8.4"] == pool)
    let conf = try String(contentsOfFile: c.conf + "/php8.4-fpm.conf", encoding: .utf8)
    #expect(conf.contains("pm = ondemand\npm.max_children = 8\npm.process_idle_timeout = 10s\n"))
    #expect(conf.contains("request_terminate_timeout = 60s\nrequest_slowlog_timeout = 5s\n"))
    try c.savePHPSettings("8.4", ini: [:], pool: FpmPool())
    #expect(c.config.fpm.isEmpty)                                  // defaults are not stored

    // A site with its own php.ini values gets its own pool and socket.
    try fm.createDirectory(atPath: tmp + "/sites/big", withIntermediateDirectories: true)
    fm.createFile(atPath: tmp + "/sites/big/.corral.json", contents: Data(#"{"php": {"memory_limit": "2048M"}}"#.utf8))
    try fm.createDirectory(atPath: tmp + "/sites/small", withIntermediateDirectories: true)
    c.config.parked = [tmp + "/sites"]
    let sites = c.sites()
    let fpm = c.fpmConf("8.4", sites: sites)
    let bigSock = c.sock("8.4", for: sites[0])
    #expect(bigSock != c.sock("8.4") && bigSock == c.sock("8.4", for: sites[0]))
    #expect(fpm.contains("[site-big]\nlisten = \"\(bigSock)\""))
    #expect(fpm.contains("php_value[memory_limit] = \"2048M\""))
    #expect(!fpm.contains("[site-small]"))
    let nginx = c.nginxConf(sites: sites, installed: ["8.4": "/x"])
    #expect(nginx.contains("unix:\(bigSock)") && nginx.contains("unix:\(c.run)/php8.4.sock"))
}

@Test func xdebugPool() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: tmp) }
    let c = Corral(home: tmp + "/home")
    try c.mkdirs(c.phpDir + "/8.4")
    try "#!/bin/sh\nexit 0\n".write(toFile: c.phpDir + "/8.4/php-fpm", atomically: true, encoding: .utf8) // php-fpm -t accepts everything
    chmod(c.phpDir + "/8.4/php-fpm", 0o755)
    try fm.createDirectory(atPath: tmp + "/sites/big", withIntermediateDirectories: true)
    fm.createFile(atPath: tmp + "/sites/big/.corral.json", contents: Data(#"{"php": {"memory_limit": "2048M"}}"#.utf8))
    try fm.createDirectory(atPath: tmp + "/sites/small", withIntermediateDirectories: true)
    c.config.parked = [tmp + "/sites"]
    c.config.php = "8.4"
    let installed = c.phpVersions(), fpm = try #require(installed["8.4"]), sites = c.sites()

    // Off by default: one pool, a fixed socket, no routing.
    #expect(c.debugVersions(installed).isEmpty)
    #expect(!c.nginxConf(sites: sites, installed: installed).contains("corral_debug"))
    #expect(c.status().map(\.0) == ["nginx", "dnsmasq", "php 8.4"])
    // An old config.json has no xdebug key.
    #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"tld": "test"}"#.utf8)).xdebug == XdebugSettings())

    // Bad values are refused before anything changes.
    var x = XdebugSettings()
    x.enabled = true
    var bad = x; bad.mode = "debug,fast"
    #expect(bad.problem != nil)
    bad = x; bad.clientPort = 0
    #expect(bad.problem != nil)
    bad = x; bad.clientHost = "a b"
    #expect(bad.problem != nil)
    bad = x; bad.startWithRequest = "sometimes"
    #expect(bad.problem != nil)
    #expect(x.problem == nil)
    #expect(throws: CorralError.self) { try c.saveXdebug(bad) }
    // A build without xdebug.so cannot run a debug pool.
    #expect(throws: CorralError.self) { try c.saveXdebug(x) }
    #expect(c.config.xdebug == XdebugSettings())

    fm.createFile(atPath: c.phpDir + "/8.4/xdebug.so", contents: Data())
    x.clientPort = 19003
    try c.saveXdebug(x)
    #expect(c.config.xdebug == x)
    #expect(c.debugVersions(installed) == ["8.4"])
    #expect(c.status().map(\.0) == ["nginx", "dnsmasq", "php 8.4", "php 8.4 debug"])
    let args = c.debugArgs(fpm)
    #expect(args.starts(with: ["-c", c.phpDir + "/8.4/php.ini", "-d", "zend_extension=\(c.phpDir)/8.4/xdebug.so"]))
    #expect(args.contains("xdebug.mode=debug,develop") && args.contains("xdebug.client_port=19003") && args.contains("xdebug.client_host=127.0.0.1"))

    #expect(try String(contentsOfFile: c.conf + "/php8.4-debug-fpm.conf", encoding: .utf8) == c.fpmConf("8.4", sites: sites, debug: true))

    // The debug pool has its own pid, log and sockets. It runs on demand and has no time limit.
    let pool = FpmPool(pm: "static", maxChildren: 8, requestTerminateTimeout: 60, slowlogTimeout: 5)
    c.config.fpm["8.4"] = pool
    let debug = c.fpmConf("8.4", sites: sites, debug: true)
    let bigDebug = c.sock("8.4", for: sites[0], debug: true)
    #expect(debug.contains("pid = \"\(c.run)/php8.4-debug-fpm.pid\"") && debug.contains("[corral-debug]\nlisten = \"\(c.run)/php8.4-debug.sock\""))
    #expect(debug.contains("pm = ondemand") && !debug.contains("request_terminate_timeout") && !debug.contains("slowlog"))
    #expect(debug.contains("[site-big]\nlisten = \"\(bigDebug)\"") && bigDebug.contains("php8.4-debug-"))
    // The normal pool does not change.
    let normal = c.fpmConf("8.4", sites: sites)
    #expect(normal.contains("pm = static") && normal.contains("request_terminate_timeout = 60s") && !normal.contains("debug"))

    // nginx sends a request with an Xdebug cookie or query argument to the debug pool.
    let nginx = c.nginxConf(sites: sites, installed: installed)
    #expect(nginx.contains("$cookie_XDEBUG_SESSION$cookie_XDEBUG_TRIGGER$arg_XDEBUG_SESSION$arg_XDEBUG_SESSION_START$arg_XDEBUG_TRIGGER"))
    #expect(nginx.contains("set $php_sock \"\(c.run)/php8.4.sock\";") && nginx.contains("if ($corral_debug) { set $php_sock \"\(c.run)/php8.4-debug.sock\"; }"))
    #expect(nginx.contains("set $php_sock \"\(c.sock("8.4", for: sites[0]))\";") && nginx.contains("set $php_sock \"\(bigDebug)\"; }"))

    // Off again: no config file, no routing.
    x.enabled = false
    try c.saveXdebug(x)
    #expect(!fm.fileExists(atPath: c.conf + "/php8.4-debug-fpm.conf"))
    #expect(!(try String(contentsOfFile: c.conf + "/nginx.conf", encoding: .utf8)).contains("corral_debug"))
}

@MainActor @Test func insightsDumpsAndLogs() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let fm = FileManager.default
    try fm.createDirectory(atPath: tmp + "/sites/shop/storage/logs", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tmp + "/sites/wp/wp-content", withIntermediateDirectories: true)
    for f in ["shop/storage/logs/laravel-2026-10-28.log", "shop/storage/logs/laravel-2026-10-29.log", "shop/storage/logs/notes.txt", "wp/wp-content/debug.log"] {
        fm.createFile(atPath: "\(tmp)/sites/\(f)", contents: nil)
    }
    let c = Corral(home: tmp + "/home")
    c.config.parked = [tmp + "/sites"]
    try c.mkdirs(c.logs)
    fm.createFile(atPath: c.logs + "/nginx-error.log", contents: nil)
    let shop = c.sites().first { $0.name == "shop" }!, wp = c.sites().first { $0.name == "wp" }!
    #expect(c.logFiles(shop) == ["\(tmp)/sites/shop/storage/logs/laravel-2026-10-29.log", "\(tmp)/sites/shop/storage/logs/laravel-2026-10-28.log", c.logs + "/nginx-error.log"])
    #expect(c.logFiles(wp) == ["\(tmp)/sites/wp/wp-content/debug.log", c.logs + "/nginx-error.log"])

    try "first line\nsecond line\nthird line\n".write(toFile: c.logs + "/nginx-error.log", atomically: true, encoding: .utf8)
    #expect(Corral.tail(c.logs + "/nginx-error.log", bytes: 15) == "third line\n")   // starts at a whole line
    #expect(Corral.tail(c.logs + "/nginx-error.log").hasPrefix("first line"))

    #expect(!c.nginxConf(sites: [shop], installed: ["8.4": "/x"]).contains("VAR_DUMPER"))
    c.config.dumps = true
    #expect(c.nginxConf(sites: [shop], installed: ["8.4": "/x"]).contains("fastcgi_param VAR_DUMPER_FORMAT server;"))
    #expect(c.nginxConf(sites: [shop], installed: ["8.4": "/x"]).contains("fastcgi_param VAR_DUMPER_SERVER 127.0.0.1:9912;"))

    let dump = Corral.Dump(time: Date(), text: "\u{1B}[39m\u{1B}[34marray:1\u{1B}[39m [\u{1B}[m\n  \u{1B}[90m0\u{1B}[39m => \u{1B}[33mhi\u{1B}[39m\u{1B}]8;;file:///x\u{1B}\\\n]",
                           source: "", request: "")
    #expect(String(dump.styled.characters) == "array:1 [\n  0 => hi\n]")
    #expect(dump.styled.runs.compactMap(\.foregroundColor) == [.cyan, .blue, .green])

    let log = LogsView.highlight("[2026-10-29 08:00:00] local.ERROR: boom\n#0 /app/x.php(12): f()\n2026/10/29 08:00:02 [warn] slow")
    #expect(String(log.characters).hasPrefix("[2026-10-29 08:00:00] local.ERROR: boom"))
    #expect(log.runs.compactMap(\.foregroundColor) == [.secondary, .red, .secondary, .orange, .secondary, .orange]) // a line's newline takes its colour
}

@Test func mailHeadersAndEnv() throws {
    let head = "From: Shop <shop@example.test>\r\nSubject: =?utf-8?Q?Gr=C3=BC=C3=9Fe_aus?=\r\n =?utf-8?B?U3RvY2tob2xt?=\r\nTo: ada@example.test"
    let h = MailMessage.headers(head)
    #expect(h["from"] == "Shop <shop@example.test>" && h["to"] == "ada@example.test")
    #expect(MailMessage.decodeWords(h["subject"]!) == "Grüße ausStockholm") // the space between two encoded words goes away
    #expect(MailMessage.decodeWords("Plain subject") == "Plain subject")
    #expect(SMTPSession.plainUser(Data("\0shop\0secret".utf8).base64EncodedString()) == "shop")

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp + "/shop", withIntermediateDirectories: true)
    let original = "APP_NAME=Shop\nMAIL_MAILER=log\nMAIL_HOST=smtp.mailgun.org\nMAIL_PASSWORD=secret\nQUEUE=sync\n"
    try original.write(toFile: tmp + "/shop/.env", atomically: true, encoding: .utf8)
    let c = Corral(home: tmp + "/home")
    let shop = Site(name: "shop", path: tmp + "/shop")
    try c.useCorralMail(shop)
    try c.useCorralMail(shop)                                    // a second run keeps the first backup
    #expect(try String(contentsOfFile: tmp + "/shop/.env.corral.bak", encoding: .utf8) == original)
    #expect(try String(contentsOfFile: tmp + "/shop/.env", encoding: .utf8)
        == "APP_NAME=Shop\nMAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PASSWORD=null\nMAIL_PORT=2525\nMAIL_USERNAME=shop\nQUEUE=sync\n")
}

@Test func zshrcPathLine() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let c = Corral(home: tmp + "/home"), zshrc = tmp + "/.zshrc"
    let original = "export PATH=\"$PATH:\(c.binDir)\"\nexport PATH=\"/opt/x:\(c.binDir):$PATH\"\nalias ll=ls\n"
    try original.write(toFile: zshrc, atomically: true, encoding: .utf8)
    #expect(try c.addToPath(zshrc))                              // the old line goes, the mixed line stays
    #expect(try String(contentsOfFile: zshrc, encoding: .utf8)
        == "export PATH=\"/opt/x:\(c.binDir):$PATH\"\nalias ll=ls\n\n\(Corral.pathComment)\nexport PATH=\"\(c.binDir):$PATH\"\n")
    #expect(try String(contentsOfFile: zshrc + ".corral.bak", encoding: .utf8) == original)
    #expect(try !c.addToPath(zshrc))                             // already last
    #expect(try c.removeFromPath(zshrc))
    #expect(try String(contentsOfFile: zshrc, encoding: .utf8) == "export PATH=\"/opt/x:\(c.binDir):$PATH\"\nalias ll=ls\n")
}

@Test func updateIgnoresOtherReleasesAndOldVersions() {
    func release(_ tag: String, sha: String? = "sha256:abc") -> [String: Any] {
        ["tag_name": tag, "assets": [["name": "Corral.zip", "browser_download_url": "https://x/\(tag)", "digest": sha as Any]]]
    }
    let builds: [String: Any] = ["tag_name": "php-builds", "assets": []]
    let newest = Corral.newest(in: [builds, release("v0.10.0"), release("v0.3.1")], than: "0.9.0")
    #expect(newest?.version == "0.10.0") // 0.10 is newer than 0.9
    #expect(newest?.sha256 == "abc")
    #expect(Corral.newest(in: [builds, release("v0.3.1")], than: "0.3.1") == nil)
    #expect(Corral.newest(in: [release("v0.4.0", sha: nil)], than: "0.3.1") == nil) // no checksum, no install
    #expect(Corral.newest(in: [release("v0.4.0", sha: nil), release("v0.3.5")], than: "0.3.1")?.version == "0.3.5")
}

@Test func wpSetupSteps() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

    let fresh = CLI.wpSetupSteps(name: "crm.pigment", host: "crm.pigment.test", dir: tmp)
    #expect(fresh[0].last == "CREATE DATABASE IF NOT EXISTS `wp_crm_pigment`")
    #expect(fresh.contains(["wp", "core", "download", "--skip-content"]))
    #expect(fresh.contains { $0.starts(with: ["wp", "config", "create", "--dbname=wp_crm_pigment"]) })
    #expect(fresh.contains { $0.contains("--url=https://crm.pigment.test") })

    // A folder that already has WordPress and a config keeps both.
    for f in ["wp-load.php", "wp-config.php"] { FileManager.default.createFile(atPath: tmp + "/" + f, contents: nil) }
    let again = CLI.wpSetupSteps(name: "crm.pigment", host: "crm.pigment.test", dir: tmp)
    #expect(!again.contains { $0.starts(with: ["wp", "core", "download"]) || $0.starts(with: ["wp", "config", "create"]) })
}

@Test func setupFromThePanel() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let site = tmp + "/site"
    try FileManager.default.createDirectory(atPath: site + "/wp-content", withIntermediateDirectories: true)
    #expect(Corral.needsWordPressSetup(site))
    #expect(!Corral.needsLaravelSetup(site))
    FileManager.default.createFile(atPath: site + "/wp-config.php", contents: nil)
    #expect(!Corral.needsWordPressSetup(site))

    FileManager.default.createFile(atPath: site + "/artisan", contents: nil)
    #expect(Corral.needsLaravelSetup(site))
    FileManager.default.createFile(atPath: site + "/.env", contents: nil)
    try FileManager.default.createDirectory(atPath: site + "/vendor", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: site + "/vendor/autoload.php", contents: nil)
    #expect(!Corral.needsLaravelSetup(site))

    // A step runs in the site folder, and a failing step reports its output.
    let c = Corral(home: tmp + "/home")
    try c.runStep(["touch", "ran-here"], in: site)
    #expect(FileManager.default.fileExists(atPath: site + "/ran-here"))
    #expect(throws: CorralError.self) { try c.runStep(["sh", "-c", "echo boom >&2; exit 3"], in: site) }
}

@Test func laravelEnvForAClone() {
    let example = "APP_NAME=Laravel\nAPP_URL=http://localhost\nDB_CONNECTION=sqlite\n# DB_HOST=127.0.0.1\n# DB_PORT=3306\n# DB_DATABASE=laravel\n# DB_USERNAME=root\n# DB_PASSWORD=\nMAIL_MAILER=log\n"
    let env = CLI.laravelEnv(example, host: "shop.test", db: "shop")
    #expect(env.contains("\nAPP_URL=https://shop.test\n"))
    #expect(env.contains("\nDB_CONNECTION=mysql\n") && !env.contains("sqlite"))
    #expect(env.contains("\nDB_DATABASE=shop\n") && env.contains("\nDB_PASSWORD=\n") && !env.contains("# DB_"))
    #expect(CLI.dbName("", "crm.pigment") == "crm_pigment")
}

@Test func portlessRoutes() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corral-test-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    #expect(Corral.portlessApps(dir: tmp).isEmpty) // no routes.json: portless is not installed or has no apps

    let routes = #"[{"hostname":"web.localhost","port":4001,"pid":111,"registeredAt":1},{"hostname":"gone.localhost","port":4002,"pid":222,"registeredAt":1},{"hostname":"db.localhost","port":5432,"pid":0,"registeredAt":1}]"#
    try routes.write(toFile: tmp + "/routes.json", atomically: true, encoding: .utf8)
    let apps = Corral.portlessApps(dir: tmp, alive: { $0 == 111 })
    #expect(apps.map(\.host) == ["db.localhost", "web.localhost"]) // the stopped app is left out, the alias stays
    #expect(apps.map(\.isAlias) == [true, false])
    #expect(apps[1].url.absoluteString == "https://web.localhost") // no proxy.port: HTTPS on 443

    try "1355".write(toFile: tmp + "/proxy.port", atomically: true, encoding: .utf8)
    #expect(Corral.portlessURL(host: "web.localhost", dir: tmp)?.absoluteString == "http://web.localhost:1355")
    FileManager.default.createFile(atPath: tmp + "/proxy.tls", contents: nil)
    #expect(Corral.portlessURL(host: "web.localhost", dir: tmp)?.absoluteString == "https://web.localhost:1355")
}
