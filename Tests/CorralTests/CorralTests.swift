import Foundation
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
    #expect(c.isManaged(fpm))
    #expect(c.cliPath(fpm) == c.phpDir + "/8.4/php")
    #expect(c.iniArgs(fpm) == ["-c", c.phpDir + "/8.4/php.ini"])
    #expect(c.cliPath("/opt/homebrew/opt/php@8.3/sbin/php-fpm") == "/opt/homebrew/opt/php@8.3/bin/php")
    #expect(c.iniArgs("/opt/homebrew/opt/php@8.3/sbin/php-fpm").isEmpty)

    c.config.php = "8.4"
    try c.writeShims(["8.4": fpm])
    let shim = try String(contentsOfFile: c.binDir + "/php", encoding: .utf8)
    // The -d MySQL socket arguments in between depend on this machine's /tmp.
    #expect(shim.hasPrefix("#!/bin/sh\nexec \"\(c.phpDir)/8.4/php\" \"-c\" \"\(c.phpDir)/8.4/php.ini\" "))
    #expect(shim.hasSuffix(" \"$@\"\n"))
    #expect(FileManager.default.isExecutableFile(atPath: c.binDir + "/php84"))
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
    #expect(c.tlds == ["internal", "test"])
    let take = c.takeoverScript(), back = c.handbackScript()
    #expect(take.contains("cp -p /etc/resolver/test \"\(Corral.resolverBackup)\""))   // keeps Herd's file
    #expect(back.contains("mv \"\(Corral.resolverBackup)\" /etc/resolver/test"))   // and restores it
    #expect(c.uninstallScript().hasPrefix(back))                                // uninstall hands .test back
    #expect(!c.uninstallScript().contains("rm -f /Library/LaunchDaemons/dev.corral.network.plist /etc/resolver"))

    c.config.tld = "test"
    #expect(c.tlds == ["test"])
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

    let c = Corral(home: tmp + "/home")
    c.config.parked = []
    try c.mkdirs(c.phpDir + "/8.4")  // PHP 8.4 is "installed", so the import downloads nothing
    for bin in ["php", "php-fpm"] { fm.createFile(atPath: "\(c.phpDir)/8.4/\(bin)", contents: Data("#!/bin/sh\n".utf8)); chmod("\(c.phpDir)/8.4/\(bin)", 0o755) }

    let r = try c.importHerd(from: herd, trust: false)
    #expect(r.parked == [tmp + "/projects"])                  // trailing slash removed, Sites and missing folder ignored
    #expect(r.links == ["blog", "rfsudev"])                   // shop is already parked, dead link ignored
    #expect(c.config.links["rfsudev"] == tmp + "/projects/rfsu")
    #expect(r.secured == ["rfsudev", "shop"])
    #expect(r.skipped == ["gone"])
    #expect(r.php == "8.4" && c.config.php == "8.4")
    #expect(fm.fileExists(atPath: c.certs + "/shop.internal.crt"))

    let again = try c.importHerd(from: herd, trust: false)    // a second run changes nothing
    #expect(again.parked.isEmpty && again.links.isEmpty && again.secured.isEmpty)
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
