import AppKit
import SwiftUI
import Testing
@testable import Corral

/// Renders every screen of the app to PNG files for design review, in light and dark mode, with sample data.
/// Runs only with CORRAL_RENDER_DIR set, for example:
///   CORRAL_RENDER_DIR=/tmp/renders swift test --filter renderUI
/// It uses a temp home (CORRAL_HOME), never the real one, and shows no window on screen.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["CORRAL_RENDER_DIR"] != nil))
func renderUI() async throws {
    let out = ProcessInfo.processInfo.environment["CORRAL_RENDER_DIR"]!
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("corral-render-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: tmp) }
    let home = tmp + "/home"
    setenv("CORRAL_HOME", home, 1)
    defer { unsetenv("CORRAL_HOME") }
    try fm.createDirectory(atPath: out, withIntermediateDirectories: true)

    // Sites in two parked folders: Laravel, WordPress and plain PHP.
    let work = tmp + "/Work", personal = tmp + "/Personal"
    for (dir, names) in [(work, ["acme-shop", "billing-api", "crm", "helpdesk", "intranet", "newsroom"]), (personal, ["blog", "portfolio", "recipes"])] {
        for name in names { try fm.createDirectory(atPath: "\(dir)/\(name)/public", withIntermediateDirectories: true) }
    }
    for laravel in ["\(work)/billing-api", "\(work)/crm", "\(work)/helpdesk"] { fm.createFile(atPath: laravel + "/artisan", contents: nil) }
    for wp in ["\(work)/newsroom", "\(personal)/blog"] { try fm.createDirectory(atPath: wp + "/wp-content", withIntermediateDirectories: true) }

    // Two PHP versions, and services that look alive (this process's pid).
    for (minor, full) in [("8.4", "8.4.27"), ("8.5", "8.5.12")] {
        let dir = "\(home)/php/\(minor)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for bin in ["php", "php-fpm"] { fm.createFile(atPath: "\(dir)/\(bin)", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]) }
        try full.write(toFile: dir + "/VERSION", atomically: true, encoding: .utf8)
        try "memory_limit = 1024M\nupload_max_filesize = 512M\nmax_execution_time = 600\ndisplay_errors = On\ndate.timezone = Europe/Stockholm\n"
            .write(toFile: dir + "/php.ini", atomically: true, encoding: .utf8)
    }
    try fm.createDirectory(atPath: home + "/run", withIntermediateDirectories: true)
    for pid in ["nginx", "dnsmasq", "php8.4-fpm", "php8.5-fpm"] { try "\(getpid())".write(toFile: "\(home)/run/\(pid).pid", atomically: true, encoding: .utf8) }

    let c = Corral(home: home)
    c.config.parked = [work, personal]
    c.config.secured = ["acme-shop", "crm", "newsroom", "blog"]
    c.config.isolated = ["billing-api": "8.4"]
    c.config.proxies = ["storefront": "http://127.0.0.1:3000"]
    c.config.mail = true
    c.config.queries = true
    try c.save()

    // Insights data: mail, requests, profiles, a log.
    try fm.createDirectory(atPath: home + "/mail", withIntermediateDirectories: true)
    let mails = [("crm", "Reset your password", "no-reply@crm.test"), ("acme-shop", "Your order #4821 has shipped", "orders@acme-shop.test"),
                 ("blog", "New comment on \u{201C}Spring planting\u{201D}", "wordpress@blog.test")]
    for (i, m) in mails.enumerated() {
        try "X-Corral-Inbox: \(m.0)\r\nFrom: \(m.2)\r\nTo: ana.lindqvist@example.com\r\nSubject: \(m.1)\r\n\r\nHello\r\n"
            .write(toFile: "\(home)/mail/\(1_794_300_000_000 + i * 60_000)-m\(i).eml", atomically: true, encoding: .utf8)
    }
    try fm.createDirectory(atPath: home + "/logs", withIntermediateDirectories: true)
    let now = Date().timeIntervalSince1970
    let requests = [
        #"{"time":\#(now - 40),"method":"GET","url":"https://crm.test/customers?page=2","status":200,"queries":[{"sql":"select * from customers limit 25 offset 25","ms":3.2,"caller":"app/Http/Controllers/CustomerController.php:41"},{"sql":"select count(*) from customers","ms":1.1,"caller":"app/Http/Controllers/CustomerController.php:41"}],"cache":[{"op":"hit","key":"settings"}]}"#,
        #"{"time":\#(now - 25),"method":"POST","url":"https://acme-shop.test/checkout","status":500,"queries":[{"sql":"select * from carts where id = ?","ms":2.4,"caller":"app/Checkout.php:88","bindings":["912"]},{"sql":"select * from carts where id = ?","ms":2.1,"caller":"app/Checkout.php:88","bindings":["912"]}],"http":[{"method":"POST","url":"https://api.stripe.test/v1/charges","status":502,"ms":1240}]}"#,
        #"{"time":\#(now - 5),"method":"GET","url":"https://blog.test/2026/spring-planting/","status":200,"queries":[{"sql":"SELECT option_value FROM wp_options WHERE option_name = 'siteurl'","ms":0.4,"caller":"wp-includes/option.php:157"}]}"#,
    ]
    try requests.joined(separator: "\n").appending("\n").write(toFile: home + "/logs/queries.jsonl", atomically: true, encoding: .utf8)
    let wpNotice = "[10-Nov-2026 06:19:19 UTC] PHP Notice:  Translation loading for the <code>woocommerce</code> domain was triggered too early. in /srv/wp-includes/functions.php on line 6131\n"
    try (wpNotice + wpNotice + "[2026-11-10 12:05:01] local.ERROR: Call to undefined method App\\Cart::total()\n#0 app/Http/Controllers/CartController.php(41): App\\Cart->total()\n" + "2026/11/10 12:04:12 [notice] 401#0: signal process started\n2026/11/10 12:05:40 [error] 401#0: *12 connect() failed (61: Connection refused) while connecting to upstream, client: 127.0.0.1, server: storefront.test\n")
        .write(toFile: home + "/logs/nginx-error.log", atomically: true, encoding: .utf8)
    try fm.createDirectory(atPath: home + "/profiles", withIntermediateDirectories: true)
    for (i, name) in ["crm_test_customers", "acme-shop_test_checkout"].enumerated() {
        try Data(count: 180_000 * (i + 1)).write(to: URL(fileURLWithPath: "\(home)/profiles/cachegrind.out.\(1_794_300_000 + i).\(4000 + i).\(name)"))
    }

    let model = Model(corral: Corral(home: home))
    model.refresh()
    try await Task.sleep(for: .seconds(1.5)) // the snapshot loads on the work queue and arrives on the main actor

    let screens: [(String, CGFloat, CGFloat?, AnyView)] = [
        ("quick-menu", 280, nil, AnyView(Panel(model: model))),
        ("main-window", 920, 520, AnyView(MainView(model: model, insights: Insights(), mail: MailServer.shared))),
        ("settings-window", 580, 520, AnyView(SettingsView(model: model))),
        ("settings-general", 580, 640, AnyView(GeneralTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("settings-php", 580, 1400, AnyView(PHPTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("settings-tools", 580, 760, AnyView(ToolsTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("settings-sites", 580, 640, AnyView(SitesTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("settings-certificates", 580, 460, AnyView(CertificatesTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("settings-about", 580, 560, AnyView(AboutTab(model: model).buttonStyle(CorralButtonStyle()).designSurface())),
        ("insights-logs", 720, 360, AnyView(LogsView(model: model, log: LogState()).designSurface())),
        ("insights-requests", 720, 460, AnyView(QueriesView(model: model))),
        ("insights-mail", 720, 400, AnyView(MailView(model: model, mail: MailServer.shared))),
        ("insights-profiles", 720, 360, AnyView(ProfilesView(model: model))),
        ("insights-dumps", 720, 360, AnyView(DumpsView(model: model, insights: Insights()))),
    ]
    // SwiftUI draws only in a window the window server shows. The window sits far off screen, so nobody sees it,
    // and screencapture copies it by its number, without the desktop around it.
    NSApplication.shared.setActivationPolicy(.accessory)
    for (name, width, height, view) in screens {
        for dark in [false, true] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).tint(.brand))
            let size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(0.8)) // lists and forms lay out on the next passes
            host.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            guard let layer = host.layer,
                  let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.translateBy(x: 0, y: size.height * scale) // AppKit layers draw top down
            ctx.scaleBy(x: scale, y: -scale)
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(out)/\(name)-\(dark ? "dark" : "light").png"))
            }
            window.orderOut(nil)
        }
    }
}
