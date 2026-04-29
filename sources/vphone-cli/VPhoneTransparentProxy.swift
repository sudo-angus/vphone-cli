import Foundation

/// Drives the host-side transparent TCP proxy workaround end-to-end so the user
/// does not have to start `scripts/vm_tproxy_start.sh` manually.
///
/// The Swift side runs as the unprivileged user and elevates via `sudo` on the
/// inherited controlling TTY. If the user already primed sudo's credential
/// cache (e.g. via `boot.sh` running `make amfidont_allow_vphone` first), this
/// is silent; otherwise sudo prompts on /dev/tty. The actually-privileged
/// work — bridge detection, `pfctl` anchor load/flush, `/dev/pf` +
/// `DIOCNATLOOK` queries, and the userspace TCP relay — stays in
/// `scripts/vm_tproxy.py` + `scripts/vm_tproxy_start.sh`, matching the manual
/// helper path. The helper is told our pid via `WATCH_PID` so it tears the
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

        do {
            let endpoint = try Self.detectBridgeEndpoint()
            print("[tproxy] detected bridge candidate interface=\(endpoint.interface) listen_addr=\(endpoint.address)")
        } catch {
            print("[tproxy] bridge candidate unavailable: \(error.localizedDescription); helper will wait and retry")
        }
        print("[tproxy] helper will auto-detect bridge; Swift is not exporting PF_INTERFACE/LISTEN_ADDR")

        let parentPid = ProcessInfo.processInfo.processIdentifier
        let inner = Self.buildInnerCommand(
            scriptPath: scriptURL.path,
            parentPid: parentPid
        )

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // sudo prompts on /dev/tty regardless of stdin, so no need to forward
        // FileHandle.standardInput here. We do route the helper's stdout/stderr
        // through pipes so we can prefix or relay them later if needed.
        p.arguments = ["/bin/zsh", "-c", inner]

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
            print("[tproxy] launching privileged helper via sudo (may prompt on /dev/tty if cache is cold)")
        } catch {
            print("[tproxy] failed to launch helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        runStopHelper()

        guard let p = process else { return }
        process = nil
        if p.isRunning {
            print("[tproxy] helper process still running; WATCH_PID cleanup remains armed")
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
        parentPid: Int32
    ) -> String {
        var parts: [String] = []
        parts.append("WATCH_PID=\(parentPid)")
        parts.append("REPLACE_EXISTING=1")
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

    private func runStopHelper() {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/bin/zsh", scriptURL.path, "stop"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if p.terminationStatus != 0 {
                print("[tproxy] stop helper exited with status \(p.terminationStatus); WATCH_PID cleanup may still handle teardown")
            }
        } catch {
            print("[tproxy] stop helper failed: \(error.localizedDescription)")
        }
    }
}
