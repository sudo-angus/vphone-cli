import AppKit
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
    private var diagnosticsWindow: VPhoneTransparentProxyDiagnosticsWindowController?
    private var diagnosticsText = ""

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
        showDiagnosticsWindow()
        appendDiagnostic("vphone tproxy diagnostics")
        appendDiagnostic("build=\(VPhoneBuildInfo.commitHash)")
        appendDiagnostic("script=\(scriptURL.path)")
        appendDiagnostic("cwd=\(FileManager.default.currentDirectoryPath)")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            appendDiagnostic("helper script not found; skipping")
            return
        }

        do {
            let endpoint = try Self.detectBridgeEndpoint()
            appendDiagnostic("swift bridge candidate: interface=\(endpoint.interface) listen_addr=\(endpoint.address)")
        } catch {
            appendDiagnostic("swift bridge candidate: \(error.localizedDescription)")
        }
        appendDiagnostic("launch mode: helper auto-detects bridge; Swift does not export PF_INTERFACE/LISTEN_ADDR")

        let parentPid = ProcessInfo.processInfo.processIdentifier
        let inner = Self.buildInnerCommand(
            scriptPath: scriptURL.path,
            parentPid: parentPid
        )
        appendDiagnostic("command: /usr/bin/sudo /bin/zsh -c \(inner)")

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
            Task { @MainActor [weak self] in
                self?.appendOutput(data, stream: "stdout")
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            FileHandle.standardError.write(data)
            Task { @MainActor [weak self] in
                self?.appendOutput(data, stream: "stderr")
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.appendDiagnostic("helper process exited status=\(status)")
                self?.runStatusProbe(label: "after helper exit")
            }
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
            appendDiagnostic("launched privileged helper via sudo pid=\(p.processIdentifier)")
            print("[tproxy] launching privileged helper via sudo (may prompt on /dev/tty if cache is cold)")
            scheduleStatusProbe(label: "post-launch", delay: 2)
        } catch {
            appendDiagnostic("failed to launch helper: \(error.localizedDescription)")
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
        appendDiagnostic("stop requested")
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

    // MARK: - Diagnostics

    private func showDiagnosticsWindow() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = VPhoneTransparentProxyDiagnosticsWindowController()
        }
        diagnosticsWindow?.showWindow(nil)
        diagnosticsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func appendOutput(_ data: Data, stream: String) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty else { continue }
            appendDiagnostic("\(stream): \(line)")
        }
    }

    private func appendDiagnostic(_ line: String) {
        let entry = "[tproxy] \(line)"
        print(entry)
        diagnosticsText += entry + "\n"
        if diagnosticsText.count > 30_000 {
            diagnosticsText.removeFirst(diagnosticsText.count - 30_000)
        }
        diagnosticsWindow?.update(text: diagnosticsText)
    }

    private func scheduleStatusProbe(label: String, delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.runStatusProbe(label: label)
        }
    }

    private func runStatusProbe(label: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptURL.path, "status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            appendDiagnostic("status probe (\(label)) exit=\(p.terminationStatus)")
            if !text.isEmpty {
                appendDiagnostic("status probe output:\n\(text)")
            }
        } catch {
            appendDiagnostic("status probe (\(label)) failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class VPhoneTransparentProxyDiagnosticsWindowController: NSWindowController {
    private let textView = NSTextView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TCP Workaround Diagnostics"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.autoresizingMask = [.width, .height]

        let header = NSTextField(labelWithString: "TCP workaround diagnostics")
        header.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 16, y: content.bounds.height - 34, width: 520, height: 18)
        header.autoresizingMask = [.maxYMargin, .width]

        let copyButton = NSButton(
            frame: NSRect(x: content.bounds.width - 116, y: content.bounds.height - 42, width: 100, height: 28)
        )
        copyButton.title = "Copy"
        copyButton.bezelStyle = .rounded
        copyButton.autoresizingMask = [.minXMargin, .maxYMargin]

        let scroll = NSScrollView(
            frame: NSRect(x: 16, y: 16, width: content.bounds.width - 32, height: content.bounds.height - 64)
        )
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        content.addSubview(header)
        content.addSubview(copyButton)
        content.addSubview(scroll)
        window.contentView = content

        super.init(window: window)

        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String) {
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
}
