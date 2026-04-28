import Foundation

/// Drives the host-side transparent TCP proxy workaround end-to-end so the user
/// does not have to start `scripts/vm_tproxy_start.sh` manually.
///
/// The Swift side runs as the unprivileged user; it auto-detects the
/// Virtualization shared bridge endpoint and asks for a one-shot admin
/// authorization via `osascript do shell script ... with administrator
/// privileges`. The actually-privileged work — `pfctl` anchor load/flush,
/// `/dev/pf` + `DIOCNATLOOK` queries, and the userspace TCP relay — stays in
/// `scripts/vm_tproxy.py` + `scripts/vm_tproxy_start.sh`, which are launched by
/// the helper. The helper is told our pid via `WATCH_PID` so it tears the
/// `pf` anchor down and exits if vphone-cli dies without sending SIGTERM.
@MainActor
final class VPhoneTransparentProxy {
    struct BridgeEndpoint: Sendable {
        let interface: String
        let address: String
    }

    private let scriptURL: URL
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init(scriptURL: URL) {
        self.scriptURL = scriptURL
    }

    static func locateHelperScript() -> URL? {
        if let override = ProcessInfo.processInfo.environment["VPHONE_TPROXY_SCRIPT"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        var roots: [URL] = []
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        roots.append(executableURL.deletingLastPathComponent())
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for root in roots {
            var dir = root
            for _ in 0 ..< 8 {
                let candidate = dir.appendingPathComponent("scripts/vm_tproxy_start.sh")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    func start() {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            print("[tproxy] helper script not found at \(scriptURL.path); skipping")
            return
        }

        let endpoint: BridgeEndpoint?
        do {
            endpoint = try Self.detectBridgeEndpoint()
        } catch {
            print("[tproxy] bridge auto-detect failed: \(error.localizedDescription); helper will retry")
            endpoint = nil
        }

        if let endpoint {
            print("[tproxy] detected bridge interface=\(endpoint.interface) listen_addr=\(endpoint.address)")
        }

        let parentPid = ProcessInfo.processInfo.processIdentifier
        let inner = Self.buildInnerCommand(
            scriptPath: scriptURL.path,
            endpoint: endpoint,
            parentPid: parentPid
        )
        let appleScript = "do shell script \"\(Self.escapeForAppleScript(inner))\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            FileHandle.standardOutput.write(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            FileHandle.standardError.write(data)
        }
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            // osascript exits 1 with `errMsg` on stderr if the user cancels the
            // password dialog; we already piped that. Just note the exit.
            if status != 0 {
                FileHandle.standardError.write(
                    Data("[tproxy] helper exited with status \(status)\n".utf8)
                )
            }
        }

        do {
            try p.run()
            process = p
            stdoutPipe = outPipe
            stderrPipe = errPipe
            print("[tproxy] launching privileged helper (one-time admin prompt may appear)")
        } catch {
            print("[tproxy] failed to launch helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            p.terminate()
            // Watchdog inside the helper script also cleans up if our SIGTERM
            // does not propagate through osascript -> sudo, so this best-effort
            // wait is enough.
            p.waitUntilExit()
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: - Bridge auto-detection

    static func detectBridgeEndpoint() throws -> BridgeEndpoint {
        let entries = try parseIfconfig()
        guard let entry = entries.first(where: { $0.hasVmenetMember && $0.address != nil }),
              let address = entry.address
        else {
            struct DetectError: LocalizedError {
                var errorDescription: String? {
                    "no bridge interface with a vmenet* member and IPv4 address found"
                }
            }
            throw DetectError()
        }
        return BridgeEndpoint(interface: entry.name, address: address)
    }

    private struct IfconfigEntry {
        let name: String
        let address: String?
        let hasVmenetMember: Bool
    }

    private static func parseIfconfig() throws -> [IfconfigEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var entries: [IfconfigEntry] = []
        var name: String?
        var addr: String?
        var hasMember = false

        func flush() {
            if let n = name {
                entries.append(IfconfigEntry(name: n, address: addr, hasVmenetMember: hasMember))
            }
            name = nil; addr = nil; hasMember = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, !first.isWhitespace {
                flush()
                let head = raw.split(separator: ":", maxSplits: 1).first ?? Substring()
                name = String(head)
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                let cols = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 2 else { continue }
                if cols[0] == "inet", addr == nil {
                    addr = String(cols[1])
                } else if cols[0] == "member:", cols[1].hasPrefix("vmenet") {
                    hasMember = true
                }
            }
        }
        flush()
        return entries
    }

    // MARK: - Command building

    private static func buildInnerCommand(
        scriptPath: String,
        endpoint: BridgeEndpoint?,
        parentPid: Int32
    ) -> String {
        var parts: [String] = []
        parts.append("WATCH_PID=\(parentPid)")
        if let endpoint {
            parts.append("PF_INTERFACE=\(shellEscape(endpoint.interface))")
            parts.append("LISTEN_ADDR=\(shellEscape(endpoint.address))")
        }
        parts.append("/bin/zsh")
        parts.append(shellEscape(scriptPath))
        parts.append("start")
        return parts.joined(separator: " ")
    }

    private static func shellEscape(_ s: String) -> String {
        // Wrap in single quotes; close, escape embedded ', re-open.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        // AppleScript string literal: escape `\` and `"`.
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }
}
