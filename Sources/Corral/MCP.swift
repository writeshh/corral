import Foundation

/// `corral mcp`: an MCP server on stdin and stdout (JSON-RPC 2.0, one message per line) for coding agents.
/// Each tool runs one `corral` command as a child process. Commands that ask questions, open a shell,
/// or delete data (db:drop, uninstall, tinker) are not tools.
extension CLI {
    struct Tool {
        let name: String, description: String, command: [String]
        var params: [(name: String, description: String, required: Bool)] = []
    }

    static let mcpTools: [Tool] = [
        Tool(name: "sites", description: "List the sites with their URL, kind (php, proxy, portless), folder, document root, PHP version, and HTTPS state.", command: ["sites", "--json"]),
        Tool(name: "status", description: "Show which services run (nginx, dnsmasq, PHP-FPM pools) and whether .test resolves to Corral.", command: ["status", "--json"]),
        Tool(name: "restart", description: "Restart nginx, dnsmasq, and PHP-FPM, then show the status. Use it after a change to .corral.json or a new Git worktree.", command: ["restart", "--json"]),
        Tool(name: "check", description: "Request every PHP site and name the likely cause of each error, for example a missing database or vendor folder.", command: ["check"]),
        Tool(name: "php_list", description: "List the installed PHP versions and the global version.", command: ["php:list", "--json"]),
        Tool(name: "use_php", description: "Set the global PHP version.", command: ["use"], params: [("version", "An installed version, for example 8.4", true)]),
        Tool(name: "isolate", description: "Pin a PHP version to one site.", command: ["isolate"],
             params: [("version", "An installed version, for example 8.4", true), ("site", "Site name. Default: the site in the server's folder", false)]),
        Tool(name: "unisolate", description: "Use the global PHP version for a site again.", command: ["unisolate"], params: [("site", "Site name. Default: the site in the server's folder", false)]),
        Tool(name: "secure", description: "Serve a site over HTTPS with a certificate from Corral's local CA.", command: ["secure"], params: [("site", "Site name. Default: the site in the server's folder", false)]),
        Tool(name: "unsecure", description: "Serve a site over HTTP.", command: ["unsecure"], params: [("site", "Site name. Default: the site in the server's folder", false)]),
        Tool(name: "queries", description: "Show what the newest requests recorded: SQL queries with timing and caller, HTTP calls, cache and queue events. Query recording must be on.",
             command: ["queries:list"], params: [("count", "Number of requests, newest last. Default 1", false)]),
        Tool(name: "mail_list", description: "List the mail that Corral caught, newest first. Message 1 is the newest.", command: ["mail"], params: [("inbox", "Only this inbox (the site name)", false)]),
        Tool(name: "mail_show", description: "Show one caught message as raw .eml.", command: ["mail:show"], params: [("n", "Message number, 1 is the newest. Default 1", false)]),
        Tool(name: "mail_links", description: "List the links in one caught message, for example a link to verify an email address.", command: ["mail:links"], params: [("n", "Message number, 1 is the newest. Default 1", false)]),
        Tool(name: "db_list", description: "List the databases on the local MySQL server (127.0.0.1, user root).", command: ["db:list"]),
        Tool(name: "db_create", description: "Create a database on the local MySQL server.", command: ["db:create"], params: [("name", "Database name. Default: the database of the site in the server's folder", false)]),
    ]

    /// The argument list for a tool call. Optional arguments come in order, so one that is missing ends the list.
    static func mcpCommand(_ tool: Tool, _ arguments: [String: Any]) throws -> [String] {
        var argv = tool.command
        for p in tool.params {
            guard let value = arguments[p.name] else {
                if p.required { throw CorralError("Missing argument: \(p.name)") }
                break
            }
            argv.append("\(value)")
        }
        return argv
    }

    /// The answer to one JSON-RPC message, or nil for a notification. `run` runs a command and gives its exit code and output.
    static func mcpResponse(_ message: [String: Any], run: ([String]) -> (Int32, String)) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var result: Any
        switch message["method"] as? String {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "corral", "version": Corral.appVersion ?? "dev"]]
        case "ping":
            result = [:] as [String: Any]
        case "tools/list":
            result = ["tools": mcpTools.map { t in
                ["name": t.name, "description": t.description, "inputSchema": [
                    "type": "object",
                    "properties": Dictionary(uniqueKeysWithValues: t.params.map { ($0.name, ["type": "string", "description": $0.description]) }),
                    "required": t.params.filter(\.required).map(\.name),
                ]] as [String: Any]
            }]
        case "tools/call":
            guard let tool = mcpTools.first(where: { $0.name == params["name"] as? String }) else {
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(params["name"] ?? "")"]]
            }
            do {
                let (status, output) = run(try mcpCommand(tool, params["arguments"] as? [String: Any] ?? [:]))
                result = ["content": [["type": "text", "text": output.isEmpty ? "Done." : output]], "isError": status != 0]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(message["method"] ?? "")"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    /// Runs `corral <argv>` with no stdin, so the child never reads the MCP messages. stderr goes into the output.
    static func runSelf(_ argv: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: Corral.executable ?? CommandLine.arguments[0])
        p.arguments = argv
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func serveMCP() -> Int32 {
        while let line = readLine() {
            let response: [String: Any]?
            if let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
                response = mcpResponse(message, run: runSelf)
            } else {
                response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
            }
            guard let response, let data = try? JSONSerialization.data(withJSONObject: response, options: .withoutEscapingSlashes) else { continue }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        return 0
    }
}
