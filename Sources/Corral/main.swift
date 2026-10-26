import Foundation

// One binary, like Herd's app + `herd` CLI pair: arguments → CLI, none → menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    MainActor.assumeIsolated { CorralApp.main() }
} else {
    exit(CLI.run(arguments))
}
