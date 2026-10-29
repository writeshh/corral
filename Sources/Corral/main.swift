import Foundation

// One binary, like Herd's app + `herd` CLI pair: arguments → CLI, none → menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    // One menu bar app at a time: a bare `corral` in a terminal must not start a second one.
    // The fd stays open for the life of the app. The kernel releases the lock when the process exits, also on a crash.
    let corral = Corral(), home = corral.home
    try? corral.mkdirs(home)
    let lock = open(home + "/app.lock", O_CREAT | O_RDWR, 0o644)
    if lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) != 0 {
        print("Corral is already running in the menu bar.\n")
        print(CLI.usage)
        exit(0)
    }
    MainActor.assumeIsolated { CorralApp.main() }
} else {
    exit(CLI.run(arguments))
}
