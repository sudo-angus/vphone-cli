import Foundation
import Observation
import VPhoneCore

/// Drives `vphone-cli vm create` headlessly for the create wizard: spawns the
/// entitled boot binary's `vm create` subcommand (the same native pipeline the
/// CLI runs — prepare → patch → DFU restore → host-mount CFW → first boot),
/// parses its `=== … ===` phase banners and `[N/M]` / `==>` sub-step markers
/// into a live phase tracker, and cancels by interrupting the whole process
/// tree (the orchestrator plus whichever VM child it has up at the time).
///
/// Elevation: the CFW host-mount step needs root. The child runs with
/// `--root-popup`, so it asks through macOS's own authentication dialog; no
/// sudoers rule and no TTY are involved. The DFU restore and the first boot run
/// the entitled boot binary, which AMFI only admits while amfidont is up — the
/// manager's usual "Authorize admin" state, checked before we get here.
@Observable
@MainActor
final class VPhoneCreateEngine {
    enum Phase: String, CaseIterable, Identifiable, Sendable {
        case prepare = "Prepare firmware"
        case patch = "Patch boot chain"
        case restore = "Restore"
        case cfw = "Install CFW"
        case firstBoot = "First boot"
        var id: String { rawValue }
    }

    enum StepStatus: Sendable { case pending, running, done }
    enum RunStatus: Sendable { case idle, running, done, failed, cancelled }

    private(set) var status: RunStatus = .idle
    private(set) var steps: [(phase: Phase, status: StepStatus)] =
        Phase.allCases.map { ($0, .pending) }
    private(set) var detail = ""
    private(set) var error: String?
    let log = VPhoneLogBuffer()

    private var process: Process?
    private var pipe: Pipe?
    private var sink: FileHandle?
    private var didCancel = false
    /// Incomplete trailing line carried between read chunks (so a `\r`-only
    /// progress redraw or a split line isn't mis-parsed).
    private var carry = ""

    var isRunning: Bool { status == .running }
    var isFinished: Bool { status == .done || status == .failed || status == .cancelled }

    // MARK: - Start

    func start(model: VPhoneCreateModel, registry: VPhoneVMRegistry, executable: URL) {
        guard status == .idle else { return }
        guard let fw = model.selectedFirmware else {
            error = "No firmware selected."
            status = .failed
            return
        }
        status = .running
        error = nil

        let repoRoot = registry.repoRoot
        if let note = Self.shareIPSWCache(repoRoot: repoRoot) {
            log.appendChunk(note + "\n")
        }

        // --project-root pins scripts/patchers/python to this clone (the boot
        // binary lives in a make-built .app whose Resources/ carries none of
        // them); --library-root makes the CLI and the manager agree on where
        // the bundle goes even when the manager was started with --library.
        let args = [
            "vm", "create", model.slug,
            "--variant", model.variant.rawValue,
            "--iphone-source", fw.iosURL,
            "--cloudos-source", fw.cloudosURL,
            "--disk-size", "\(model.diskGB)",
            "--cpu", "\(model.cpu)",
            "--memory", "\(model.memoryMB)",
            "--library-root", registry.libraryRoot.path,
            "--project-root", repoRoot.path,
            "--root-popup",
            "-v",
        ]
        log.appendChunk("[create] \(executable.lastPathComponent) \(args.joined(separator: " "))\n")

        // Durable copy of the full run output.
        let logURL = repoRoot.appendingPathComponent("setup_logs/create-\(model.slug).log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        sink = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = repoRoot
        p.environment = VPhoneToolEnv.environment(repoRoot: repoRoot)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let sinkBox = sink
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            sinkBox?.write(data)
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.ingest(text) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.finish(code: code) }
        }

        do {
            try p.run()
            process = p
            self.pipe = pipe
        } catch {
            self.error = "Could not launch vm create: \(error.localizedDescription)"
            status = .failed
        }
    }

    /// Reuse the clone's `ipsws/` download cache for the per-user layout
    /// (`~/.vphone/ipsws`) by linking one to the other, so moving the wizard
    /// onto `vm create` doesn't re-download firmware the make flow already
    /// fetched. Only ever creates the link; an existing user cache is left alone.
    nonisolated private static func shareIPSWCache(repoRoot: URL) -> String? {
        let fm = FileManager.default
        let userCache = VPhoneResources.userDataRoot().appendingPathComponent("ipsws")
        let repoCache = repoRoot.appendingPathComponent("ipsws")
        var isDir: ObjCBool = false
        guard !fm.fileExists(atPath: userCache.path),
              (try? userCache.checkResourceIsReachable()) != true,
              fm.fileExists(atPath: repoCache.path, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        do {
            try fm.createDirectory(at: userCache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: userCache, withDestinationURL: repoCache)
            return "[create] linked \(userCache.path) → \(repoCache.path) (reusing the existing IPSW cache)"
        } catch {
            return "[create] could not link the IPSW cache: \(error.localizedDescription)"
        }
    }

    // MARK: - Cancel

    func cancel() {
        guard status == .running, let p = process else { return }
        didCancel = true
        detail = "Cancelling…"
        log.appendChunk("[create] cancel requested — interrupting vm create and its VM children\n")
        let root = p.processIdentifier
        Task.detached { await Self.interruptTree(rootPID: root) }
    }

    /// A terminal's Ctrl-C reaches the orchestrator *and* its DFU / first-boot
    /// VM child through the foreground process group; the manager has no such
    /// group, and the orchestrator has no signal handler of its own, so
    /// interrupting only the parent would orphan a running VM. Collect the tree
    /// first (once the parent dies the children are re-parented and untraceable),
    /// interrupt children before parent, then SIGKILL whatever ignored it.
    nonisolated private static func interruptTree(rootPID: pid_t) async {
        let tree = descendants(of: rootPID)
        for pid in tree.reversed() { kill(pid, SIGINT) }
        kill(rootPID, SIGINT)
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        for pid in tree + [rootPID] where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    nonisolated private static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", "\(parent)"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let child = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                    result.append(child)
                    queue.append(child)
                }
            }
        }
        return result
    }

    // MARK: - Parsing

    private func ingest(_ text: String) {
        carry += VPhoneANSI.strip(text)
        // Cut on \n (real line) and \r (progress redraw) so aria2c (\n-per-tick)
        // and tqdm (\r-per-tick) both resolve to one logical line.
        while let idx = carry.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let segment = String(carry[..<idx])
            var next = carry.index(after: idx)
            if carry[idx] == "\r", next < carry.endIndex, carry[next] == "\n" {
                next = carry.index(after: next) // CRLF → one terminator
            }
            carry = String(carry[next...])
            handleLine(segment)
        }
        // Live tail of an unterminated progress bar (tqdm before its first \n).
        let tail = carry.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty, Self.isProgressLine(tail) { detail = Self.friendlyProgress(tail) }
    }

    /// One logical line: download/restore progress is summarised into the live
    /// `detail` line only; everything else flows into the scrollback pane (the
    /// durable `create-*.log` keeps the raw stream regardless).
    private func handleLine(_ segment: String) {
        let line = segment.trimmingCharacters(in: .whitespaces)
        if Self.isProgressLine(line) {
            detail = Self.friendlyProgress(line)
            return
        }
        log.appendChunk(segment + "\n")
        guard !line.isEmpty else { return }

        if line.hasPrefix("==="), line.hasSuffix("===") {
            let label = line.replacingOccurrences(of: "=", with: "").trimmingCharacters(in: .whitespaces)
            advance(toBanner: label)
            return
        }
        if line.hasPrefix("[") || line.hasPrefix("==>") {
            detail = String(line.prefix(160))
        }
    }

    // MARK: Progress lines

    /// aria2c (`[#…(NN%)…]`) and tqdm (`NN%|…it/s]`) download/restore bars.
    private static func isProgressLine(_ line: String) -> Bool {
        if line.hasPrefix("[#") { return true }
        if line.contains("it/s]") { return true }
        return line.range(of: #"^\s*\d+%\|"#, options: .regularExpression) != nil
    }

    private static func friendlyProgress(_ line: String) -> String {
        if line.hasPrefix("[#") {
            var parts = ["Downloading firmware"]
            if let pct = between(line, after: "(", before: "%)") { parts.append("\(pct)%") }
            if let sizes = between(line, after: " ", before: "("), sizes.contains("/") { parts.append(sizes) }
            if let dl = between(line, after: "DL:", before: " ") { parts.append("\(dl)/s") }
            if let eta = between(line, after: "ETA:", before: "]") ?? between(line, after: "ETA:", before: " ") {
                parts.append("ETA \(eta)")
            }
            return parts.joined(separator: " · ")
        }
        if let pctRange = line.range(of: #"^\s*\d+%"#, options: .regularExpression) {
            var parts = ["Restoring", line[pctRange].trimmingCharacters(in: .whitespaces)]
            if let count = between(line, after: "| ", before: " ["), count.contains("/") {
                parts.append(count.trimmingCharacters(in: .whitespaces))
            }
            if let eta = between(line, after: "<", before: ",") { parts.append("ETA \(eta)") }
            return parts.joined(separator: " · ")
        }
        return String(line.prefix(160))
    }

    private static func between(_ s: String, after: String, before: String) -> String? {
        guard let a = s.range(of: after) else { return nil }
        let rest = s[a.upperBound...]
        guard let b = rest.range(of: before) else { return nil }
        return String(rest[..<b.lowerBound])
    }

    /// Banners as `VPhoneCreateOrchestrator` prints them: `vm new`, `fw
    /// prepare`, `fw patch`, `Restore phase`, `CFW install (host-mount)`, `First
    /// boot`, `JB Finalize`, `Done`, then `Boot analysis` (which boots the VM
    /// once more to verify it), or `Start VM` for the patchless variant.
    private func advance(toBanner label: String) {
        let mapped: Phase? = {
            if label.hasPrefix("vm new") || label.hasPrefix("fw prepare") { return .prepare }
            if label.hasPrefix("fw patch") { return .patch }
            if label.contains("Restore") { return .restore }
            if label.contains("CFW") { return .cfw }
            if label.contains("First boot") || label.contains("Boot analysis") || label.contains("Start VM") {
                return .firstBoot
            }
            return nil
        }()

        // "Done" precedes the verification boot; the exit code decides completion.
        if label.contains("Done") || label.contains("JB Finalize") {
            detail = label
            return
        }
        guard let phase = mapped, let idx = steps.firstIndex(where: { $0.phase == phase }) else { return }
        for i in 0 ..< idx { steps[i].status = .done }
        steps[idx].status = .running
        detail = label.contains("Boot analysis") ? "Boot analysis — verifying the VM boots" : label
    }

    private func finish(code: Int32) {
        if !carry.isEmpty { handleLine(carry); carry = "" }
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? sink?.close()
        sink = nil
        process = nil

        if didCancel {
            status = .cancelled
            detail = "Cancelled"
            return
        }
        if code == 0 {
            for i in steps.indices { steps[i].status = .done }
            status = .done
            detail = "Done"
        } else {
            // Completed phases stay marked done; the running one stays as-is so
            // the UI shows where it stopped.
            status = .failed
            error = "vm create exited with code \(code). See the log for the failing step."
        }
    }
}
