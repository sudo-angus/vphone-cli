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

    /// Ensure the AMFI bypass daemon is up. Passwordless once authorized.
    func ensureAmfidont() async -> AmfidontResult {
        let repoPath = repoRoot.path
        if Self.isAmfidontRunning(repoPath: repoPath) { return .running }
        guard let python = resolveAmfidontPython() else { return .unavailable }
        return await Task.detached {
            Self.startAmfidont(python: python, repoPath: repoPath)
        }.value
    }

    func isAmfidontRunning() -> Bool {
        Self.isAmfidontRunning(repoPath: repoRoot.path)
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

    nonisolated private static func isAmfidontRunning(repoPath: String) -> Bool {
        let (rc, out) = runCapture("/usr/bin/pgrep", ["-fl", "amfidont"])
        guard rc == 0 else { return false }
        // The transient `python -c import amfidont` probe also matches "amfidont";
        // the live daemon is the one carrying our --path.
        return out.split(separator: "\n").contains { $0.contains(repoPath) }
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
            if isAmfidontRunning(repoPath: repoPath) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if text.contains("a password is required") || text.contains("a terminal is required") {
            return .needsAuthorization
        }
        if isAmfidontRunning(repoPath: repoPath) { return .started }
        return .failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
