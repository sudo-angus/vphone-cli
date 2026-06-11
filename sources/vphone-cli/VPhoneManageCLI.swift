import ArgumentParser
import Foundation

/// `vphone-cli manage` — launches the VM manager GUI. Execution happens in
/// `main.swift` (it needs to drive the AppKit run loop), so `run()` is a no-op
/// like the boot subcommand.
struct VPhoneManageCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manage",
        abstract: "Open the VPhone VM manager (GUI)",
        discussion: """
        A Dock app that lists every VM (each a directory with a config.plist),
        starts/stops/restarts them by supervising `vphone-cli boot` children,
        monitors guest health, captures per-VM logs, and authorizes the AMFI
        bypass once via a scoped sudoers rule.

        Launching the app bundle with no arguments is equivalent to this command.
        """
    )

    @Option(name: .long, help: "VM library root to scan for VMs (default: <repo>/vms; the legacy vm/ is always included).")
    var library: String?

    mutating func run() throws {}
}
