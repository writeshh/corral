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
    #expect(conf.contains("server_name shop.internal *.shop.internal;"))
    #expect(conf.contains("listen 127.0.0.1:8543 ssl;"))
    #expect(conf.contains("return 301 https://$host$request_uri;"))
    #expect(conf.contains("php8.4.sock"))
    #expect(conf.contains("root \"\(tmp)/parked/API Docs\";"))
    #expect(conf.components(separatedBy: "listen 127.0.0.1:8543").count == 2) // only shop is secured

    // CA + leaf cert chain verifies, with the wildcard SAN.
    #expect(try c.ensureCA() == true)
    #expect(try c.ensureCA() == false)
    try c.makeCert("shop.internal")
    let verify = try c.sh("/usr/bin/openssl", ["verify", "-CAfile", c.caPem, c.certs + "/shop.internal.crt"])
    #expect(verify.contains("OK"))
    let text = try c.sh("/usr/bin/openssl", ["x509", "-noout", "-text", "-in", c.certs + "/shop.internal.crt"])
    #expect(text.contains("DNS:*.shop.internal"))

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
    #expect(shim == "#!/bin/sh\nexec \"\(c.phpDir)/8.4/php\" \"-c\" \"\(c.phpDir)/8.4/php.ini\" \"$@\"\n")
    #expect(FileManager.default.isExecutableFile(atPath: c.binDir + "/php84"))
}
