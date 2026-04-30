import AppKit
import ArgumentParser
import Darwin
import Foundation

// Many code paths in vphone-cli (vsock byte pumps, host bridges, sub-process
// stdio) write to sockets/pipes whose peers can disappear at any time. Default
// SIGPIPE handling terminates the process with exit 141. Ignore it globally so
// errno=EPIPE surfaces through normal error paths instead.
signal(SIGPIPE, SIG_IGN)

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    case var patch as PatchFirmwareCLI:
        try patch.run()

    case var patch as PatchComponentCLI:
        try patch.run()

    default:
        break
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
