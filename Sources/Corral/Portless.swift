import Foundation

/// An app that portless serves. Corral only lists it: portless keeps its own proxy, certificates and routes.
struct PortlessApp: Identifiable, Equatable {
    let host: String    // shop.localhost
    let port: Int       // the port of the app behind portless
    let isAlias: Bool   // a static route from `portless alias`, with no process of its own
    let url: URL
    var id: String { host }
}

extension Corral {
    /// portless writes its routes to routes.json in ~/.portless (PORTLESS_STATE_DIR changes the folder).
    /// Reading the file needs no `portless` command, so it also works in the menu bar app, which has a short PATH.
    static func portlessApps(dir: String? = nil, alive: (pid_t) -> Bool = { kill($0, 0) == 0 }) -> [PortlessApp] {
        let dir = dir ?? ProcessInfo.processInfo.environment["PORTLESS_STATE_DIR"] ?? NSHomeDirectory() + "/.portless"
        guard let data = FileManager.default.contents(atPath: dir + "/routes.json"),
              let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return routes.compactMap { route in
            guard let host = route["hostname"] as? String, let port = route["port"] as? Int,
                  let url = portlessURL(host: host, dir: dir) else { return nil }
            let pid = route["pid"] as? Int ?? 0
            guard pid == 0 || alive(pid_t(pid)) else { return nil } // the app stopped, and portless has not cleaned up yet
            return PortlessApp(host: host, port: port, isAlias: pid == 0, url: url)
        }.sorted { $0.host < $1.host }
    }

    /// The address that portless gives an app. The proxy writes `proxy.port`, and `proxy.tls` when it serves HTTPS.
    /// Without a port file, portless uses HTTPS on 443.
    static func portlessURL(host: String, dir: String) -> URL? {
        let port = (try? String(contentsOfFile: dir + "/proxy.port", encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 443
        let https = port == 443 || FileManager.default.fileExists(atPath: dir + "/proxy.tls")
        let standard = https ? 443 : 80
        return URL(string: "\(https ? "https" : "http")://\(host)\(port == standard ? "" : ":\(port)")")
    }
}
