import Foundation
import Observation

/// Drives `make setup_machine` headlessly for the create wizard: spawns it with
/// `NONE_INTERACTIVE=1` and `VM_DIR=vms/<slug>` (so the existing `vm/` is never
/// touched), parses its `=== … ===` phase banners and `[N/M]` / `==>` sub-step
/// markers into a live phase tracker, and cancels by SIGINT (whose trap in
/// setup_machine.sh tears down the DFU/iproxy children and releases VM locks).
@Observable
@MainActor
final class VPhoneCreateEngine {
    enum Phase: String, CaseIterable, Identifiable, Sendable {
        case firmwarePrep = "Firmware prep"
        case firmwarePatch = "Firmware patch"
        case restore = "Restore"
        case ramdiskCFW = "Ramdisk + CFW"
        case firstBoot = "First boot"
        var id: String { rawValue }
    }

    enum StepStatus: Sendable { case pending, running, done }
    enum RunStatus: Sendable { case idle, running, done, failed, cancelled }

    private(set) var status: RunStatus = .idle
    /// Ordered phase tracker; LESS skips Ramdisk + CFW (it just never lights up).
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

    func start(model: VPhoneCreateModel, repoRoot: URL) {
        guard status == .idle else { return }
        guard let fw = model.selectedFirmware else {
            error = "No firmware selected."
            status = .failed
            return
        }
        status = .running
        error = nil

        var args = [
            "setup_machine",
            "NONE_INTERACTIVE=1",
            "SKIP_PROJECT_SETUP=1",
            "VM_DIR=vms/\(model.slug)",
            "CPU=\(model.cpu)",
            "MEMORY=\(model.memoryMB)",
            "DISK_SIZE=\(model.diskGB)",
            "IPHONE_VERSION=\(fw.version)",
            "IPHONE_BUILD=\(fw.build)",
        ]
        if let flag = model.variant.makeFlag { args.append(flag) }

        log.appendChunk("[create] make \(args.joined(separator: " "))\n")
        if model.variant == .less {
            log.appendChunk("[create] note: the Patchless variant also needs `sudo make fw_patch_less`, which is not yet covered by the passwordless rule — it may stall.\n")
        }

        // Durable copy of the full run output.
        let logURL = repoRoot.appendingPathComponent("setup_logs/create-\(model.slug).log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        sink = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
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
            self.error = "Could not launch setup_machine: \(error.localizedDescription)"
            status = .failed
        }
    }

    func cancel() {
        guard status == .running else { return }
        didCancel = true
        detail = "Cancelling…"
        log.appendChunk("[create] cancel requested — sending SIGINT\n")
        process?.interrupt() // setup_machine's trap tears down children + releases locks
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

    /// One logical line: build progress is summarised into the live `detail`
    /// line only; everything else flows into the scrollback pane (the durable
    /// `create-*.log` keeps the raw stream regardless).
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

    private func advance(toBanner label: String) {
        let mapped: Phase? = {
            if label.contains("Firmware prep") { return .firmwarePrep }
            if label.contains("Firmware patch") { return .firmwarePatch }
            if label.contains("Restore") { return .restore }
            if label.contains("Ramdisk") { return .ramdiskCFW }
            if label.contains("First boot") { return .firstBoot }
            return nil
        }()

        if label.contains("Done") || label.contains("Boot analysis") {
            for i in steps.indices where steps[i].status != .pending { steps[i].status = .done }
            detail = label
            return
        }
        guard let phase = mapped, let idx = steps.firstIndex(where: { $0.phase == phase }) else { return }
        for i in 0 ..< idx { steps[i].status = .done }
        steps[idx].status = .running
        detail = label
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
            markRunningFailed()
            return
        }
        if code == 0 {
            for i in steps.indices { steps[i].status = .done }
            status = .done
            detail = "Done"
        } else {
            status = .failed
            error = "setup_machine exited with code \(code). See the log for the failing step."
            markRunningFailed()
        }
    }

    private func markRunningFailed() {
        // Leave completed phases marked done; the running one stays as-is so the
        // UI shows where it stopped.
    }
}
