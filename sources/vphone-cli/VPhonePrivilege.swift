import Foundation

/// One-time, scoped admin authorization for the manager.
///
/// vphone elevates for exactly two things: starting the `amfidont` daemon (so
/// AMFI doesn't SIGKILL the signed binary) and the `--tcp-workaround` pf/proxy
/// helper. The CLI flow re-prompts for a sudo password on every boot. The
/// manager replaces that with a single admin prompt that installs a
/// `visudo`-validated `/etc/sudoers.d/vphone` granting NOPASSWD for *only* those
/// exact commands. Afterward amfidont can be (re)started silently and every VM
/// boots without a prompt, surviving host reboots. "Remove authorization"
/// deletes the file.
@MainActor
final class VPhonePrivilege {
    enum AuthStatus: Sendable, Equatable {
        case authorized
        case notAuthorized
    }

    enum AmfidontResult: Sendable, Equatable {
        case running // already up
        case started // we started it
        case needsAuthorization // sudo -n refused (no rule / no cached cred)
        case unavailable // amfidont module not importable by any python
        case failed(String)
    }

    let repoRoot: URL
    let userName: String
    private let sudoersPath = "/etc/sudoers.d/vphone"

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        userName = NSUserName()
    }

    // MARK: - Status

    /// `/etc/sudoers.d` is world-traversable (0755), so a normal user can stat
    /// our file even though it is root:wheel 0440 and unreadable.
    func authStatus() -> AuthStatus {
        FileManager.default.fileExists(atPath: sudoersPath) ? .authorized : .notAuthorized
    }

    // MARK: - Authorize / deauthorize

    func authorize() async throws {
        guard let python = resolveAmfidontPython() else {
            throw VPhoneManagerError.amfidontMissing
        }
        let content = sudoersContent(python: python)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-sudoers-\(UUID().uuidString)")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Validate as the user before we ever touch /etc.
        let (vrc, vout) = Self.runCapture("/usr/sbin/visudo", ["-cf", tmp.path])
        guard vrc == 0 else { throw VPhoneManagerError.sudoersInvalid(vout) }

        // One elevated step: install with strict perms, then re-validate the
        // whole config and roll back if anything is wrong.
        let dest = sudoersPath
        let install = "/usr/bin/install -m 0440 -o root -g wheel \(Self.shq(tmp.path)) \(Self.shq(dest))"
        let verify = "/usr/sbin/visudo -c >/dev/null 2>&1 || (/bin/rm -f \(Self.shq(dest)); exit 2)"
        try await Self.runAdminShell("\(install) && (\(verify))")
    }

    func deauthorize() async throws {
        try await Self.runAdminShell("/bin/rm -f \(Self.shq(sudoersPath))")
    }

    private func sudoersContent(python: String) -> String {
        let tproxy = repoRoot.appendingPathComponent("scripts/vm_tproxy_start.sh").path
        var commands = [
            "\(python) -m amfidont daemon --path \(repoRoot.path) --spoof-apple",
            "\(tproxy) start",
            "\(tproxy) stop",
            "/usr/bin/hdiutil",
        ]
        // The ramdisk build extracts the SSH toolchain into the mounted ramdisk
        // as root via gnu-tar (scripts/ramdisk_build.py). Without this the create
        // stalls partway through on a surprise mid-run sudo prompt.
        if let gtar = resolveGtar() { commands.append(gtar) }

        let rules = commands
            .map { "\(userName) ALL=(root) NOPASSWD: \($0)" }
            .joined(separator: "\n")
        return """
        # vphone manager — scoped passwordless elevation. Managed by VPhone.app.
        # Installed by the manager's "Authorize admin" action; remove with
        # "Remove authorization" (or: sudo rm /etc/sudoers.d/vphone).
        Defaults env_keep += "WATCH_PID REPLACE_EXISTING"
        \(rules)

        """
    }

    /// Whether a VM *create* can run hands-free. Beyond boot's elevations it
    /// mounts the CFW DMG (`hdiutil`) and extracts the ramdisk toolchain
    /// (`gtar`). A rule predating either line still prompts mid-create, so both
    /// must be NOPASSWD-allowed; a `false` here makes the wizard (re)authorize.
    ///
    /// Inspect the *rule listing* rather than `sudo -n -l <cmd>` per command:
    /// the per-command form returns "allowed" off a warm sudo timestamp even
    /// when the command isn't NOPASSWD, so a stale rule (missing hdiutil/gtar)
    /// would pass here and then prompt for real at the privileged step.
    func canCreatePasswordless() -> Bool {
        let (rc, listing) = Self.runCapture("/usr/bin/sudo", ["-n", "-l"])
        guard rc == 0, listing.contains("NOPASSWD:"), listing.contains("/usr/bin/hdiutil")
        else { return false }
        if let gtar = resolveGtar(), !listing.contains(gtar) { return false }
        return true
    }

    /// Absolute path `sudo gtar` resolves to in the create subprocess (Homebrew
    /// gnu-tar). Must match what `ramdisk_build.py` invokes so the sudoers rule
    /// matches. nil when gnu-tar isn't installed (create will fail its own
    /// prerequisite check first).
    func resolveGtar() -> String? {
        for candidate in ["/opt/homebrew/bin/gtar", "/usr/local/bin/gtar"]
            where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let (rc, out) = Self.runCapture("/usr/bin/which", ["gtar"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return rc == 0 && !path.isEmpty ? path : nil
    }

    // MARK: - amfidont

    /// Ensure the AMFI bypass is up *and* self-healing. Passwordless once
    /// authorized.
    ///
    /// amfid is launchd-recycled periodically; when it is, amfidont's lldb
    /// session dies (`Unexpected process state 10`) and the worker exits,
    /// silently dropping the bypass. `amfidont_supervisor.sh` watches for that
    /// and relaunches the worker, so the durable goal is "a supervisor is
    /// running", not "a worker exists right now".
    func ensureAmfidont() async -> AmfidontResult {
        let repoPath = repoRoot.path
        // Supervisor already minding the worker — nothing to do.
        if Self.isSupervisorRunning(repoPath: repoPath) { return .running }
        guard let python = resolveAmfidontPython() else { return .unavailable }
        return await Task.detached {
            // A worker is already up (manual/legacy daemon, no supervisor):
            // attach a supervisor to keep it alive, don't double-start.
            if Self.isWorkerRunning(repoPath: repoPath) {
                Self.startSupervisor(python: python, repoPath: repoPath)
                return .running
            }
            // Cold start: launch once directly so a real authorization or
            // availability problem surfaces synchronously, then hand off to the
            // supervisor for the recurring amfid-recycle recovery.
            let first = Self.startAmfidont(python: python, repoPath: repoPath)
            switch first {
            case .started, .running:
                Self.startSupervisor(python: python, repoPath: repoPath)
                return .started
            case .needsAuthorization, .unavailable, .failed:
                return first
            }
        }.value
    }

    func isAmfidontRunning() -> Bool {
        let repoPath = repoRoot.path
        return Self.isSupervisorRunning(repoPath: repoPath) || Self.isWorkerRunning(repoPath: repoPath)
    }

    // MARK: - python resolution

    /// First python3 that can `import amfidont`, mirroring
    /// `scripts/start_amfidont_for_vphone.sh`.
    func resolveAmfidontPython() -> String? {
        var candidates: [String] = []
        let (xc, xcout) = Self.runCapture("/usr/bin/xcrun", ["-f", "python3"])
        if xc == 0 {
            let p = xcout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { candidates.append(p) }
        }
        candidates.append("/usr/bin/python3")

        var seen = Set<String>()
        for c in candidates where seen.insert(c).inserted {
            let (rc, _) = Self.runCapture(c, ["-c", "import amfidont"])
            if rc == 0 { return c }
        }
        return nil
    }

    // MARK: - nonisolated helpers

    /// Processes whose argv mentions amfidont *and* our repo path. The transient
    /// `python -c import amfidont` probe also matches "amfidont", so the repo
    /// path is what isolates our own processes.
    nonisolated private static func amfidontLines(repoPath: String) -> [String] {
        let (rc, out) = runCapture("/usr/bin/pgrep", ["-fl", "amfidont"])
        guard rc == 0 else { return [] }
        return out.split(separator: "\n").map(String.init).filter { $0.contains(repoPath) }
    }

    nonisolated private static func isSupervisorRunning(repoPath: String) -> Bool {
        amfidontLines(repoPath: repoPath).contains { $0.contains("amfidont_supervisor") }
    }

    /// The long-lived bypass worker: `python -m amfidont --spoof-apple --path
    /// REPO`. Excludes the supervisor and the short-lived `daemon` launcher,
    /// which carries a ` daemon ` token the worker does not.
    nonisolated private static func isWorkerRunning(repoPath: String) -> Bool {
        amfidontLines(repoPath: repoPath).contains {
            !$0.contains("supervisor") && !$0.contains(" daemon ")
        }
    }

    /// Launch the watchdog (as the current user). It self-daemonizes and uses
    /// the scoped NOPASSWD rule for its own `sudo -n` worker launches, so this
    /// needs no extra privilege and returns promptly.
    nonisolated private static func startSupervisor(python: String, repoPath: String) {
        let script = repoPath + "/scripts/amfidont_supervisor.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script, "--python", python, "--path", repoPath]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return }
        // The foreground invocation exits as soon as it forks the detached loop.
        _ = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
    }

    nonisolated private static func startAmfidont(python: String, repoPath: String) -> AmfidontResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", python, "-m", "amfidont", "daemon", "--path", repoPath, "--spoof-apple"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return .failed("failed to launch sudo") }

        // amfidont self-daemonizes, so sudo returns promptly; poll to confirm.
        for _ in 0 ..< 12 {
            if !p.isRunning { break }
            if isWorkerRunning(repoPath: repoPath) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // The worker is up — that *is* the success signal, so return before
        // touching the pipe. The daemonized worker inherits this pipe's write
        // end and holds it open for its whole lifetime, so reading to EOF would
        // block here forever (it wedged the manager's bootstrap, pinning every
        // VM at "Starting" because `health.start()` never got to run).
        if isWorkerRunning(repoPath: repoPath) { return .started }

        // Worker didn't come up: read the launcher's banner to tell an auth
        // prompt apart from a real failure. Bounded (never waits for EOF) so a
        // worker that daemonized but escaped detection can't reblock us.
        let text = drainAvailable(out.fileHandleForReading, deadline: 1.0)
        if text.contains("a password is required") || text.contains("a terminal is required") {
            return .needsAuthorization
        }
        // The daemon launched a worker but it isn't up yet. The common cause is
        // amfid being mid-recycle, so the worker's lldb attach raced and exited
        // (`Unexpected process state 10`). That's recoverable — the supervisor
        // will relaunch it — so report success-pending rather than a hard fail.
        if text.contains("amfidont daemon started") { return .started }
        return .failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read whatever is buffered on `handle` without waiting for EOF. We launch
    /// daemons that keep this pipe's write end open for their whole lifetime, so
    /// `readDataToEndOfFile()` can block indefinitely; the startup banner we need
    /// is already buffered by the time we call this. `poll()` slices give up once
    /// the pipe goes quiet (or hits `deadline`), so this always returns.
    nonisolated private static func drainAvailable(_ handle: FileHandle, deadline: TimeInterval) -> String {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return "" }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100) // 100 ms slice
            if r > 0, pfd.revents & Int16(POLLIN) != 0 {
                let n = read(fd, &buf, buf.count)
                if n > 0 { data.append(contentsOf: buf[..<n]) } else { break } // EOF / error
            } else if r == 0 {
                if !data.isEmpty { break } // quiet after we already captured output
            } else {
                break // poll error
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func runCapture(_ launch: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Run a shell command once with a single GUI admin prompt via
    /// AuthorizationServices (`osascript ... with administrator privileges`).
    nonisolated private static func runAdminShell(_ shell: String) async throws {
        try await Task.detached {
            let apple = "do shell script \"\(escapeForAppleScript(shell))\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", apple]
            let err = Pipe()
            p.standardOutput = Pipe()
            p.standardError = err
            try p.run()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: data, encoding: .utf8) ?? ""
                if msg.contains("-128") || msg.lowercased().contains("cancel") {
                    throw VPhoneManagerError.authorizationCancelled
                }
                throw VPhoneManagerError.authorizationFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }

    /// Single-quote for /bin/sh.
    nonisolated private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for embedding inside an AppleScript double-quoted string.
    nonisolated private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
