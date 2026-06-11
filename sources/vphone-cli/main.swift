import AppKit
import ArgumentParser
import Darwin
import Foundation

// Many code paths in vphone-cli (vsock byte pumps, host bridges, sub-process
// stdio) write to sockets/pipes whose peers can disappear at any time. Default
// SIGPIPE handling terminates the process with exit 141. Ignore it globally so
// errno=EPIPE surfaces through normal error paths instead.
signal(SIGPIPE, SIG_IGN)

// Force line buffering on stdout. When this process runs standalone its stdout
// is a TTY (already line-buffered), but under the manager GUI it is captured
// over a pipe, where libc defaults to 4 KB block buffering. The VM serial
// console is written with an unbuffered FileHandle.write, so it streams at
// once, while every host log line (`[vphone]`/`[usbmux]`/`[socks5]`/`[control]`,
// i.e. all of the Network pane) goes through print()→stdio and would otherwise
// sit in the block buffer — arriving in late bursts and out of order relative
// to the serial output. Line buffering makes each log line flush as written.
setvbuf(stdout, nil, _IOLBF, 0)

// A bare launch with no arguments (e.g. double-clicking the app bundle in
// Finder) defaults to the manager GUI rather than the config-less boot path,
// which would otherwise fail. Explicit subcommands/flags are untouched.
var argv = CommandLine.arguments
if argv.count == 1 {
    argv.append("manage")
}

do {
    let command = try VPhoneCLI.parseAsRoot(Array(argv.dropFirst()))

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    case let manage as VPhoneManageCLI:
        let app = NSApplication.shared
        let delegate = VPhoneManagerAppDelegate(cli: manage)
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
