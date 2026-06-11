import Foundation

/// Thread-safe append-only writer for a VM's durable run log. The pipe
/// readability handler runs off the main actor, so this is `@unchecked
/// Sendable` and serializes writes with a lock.
private final class VPhoneLogSink: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init?(fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        handle = h
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

/// Owns the lifecycle of `vphone-cli boot` child processes — one per running
/// VM. The boot binary is hard one-VM-per-process (it `exit()`s when its guest
/// stops and wires the serial console to its own stdio), so the manager treats
/// each VM as a supervised child: launch with per-VM forwarded ports, capture
/// the merged stdout/stderr into the live log buffer and a rolling file, and
/// stop cleanly with SIGINT (which the child turns into a graceful AppKit
/// teardown). Children that were already running when the manager starts — an
/// older `make boot`, or a relaunch — are *adopted* via their `vphone.sock`.
@MainActor
final class VPhoneSupervisor {
    /// Live bookkeeping for one owned child.
    private final class Running {
        let process: Process
        let sink: VPhoneLogSink
        let pipe: Pipe
        var intentionalStop = false
        var exitWaiters: [CheckedContinuation<Void, Never>] = []

        init(process: Process, sink: VPhoneLogSink, pipe: Pipe) {
            self.process = process
            self.sink = sink
            self.pipe = pipe
        }
    }

    private let executableURL: URL
    private let repoRoot: URL
    private var running: [String: Running] = [:]
    /// Only one VM may hold the (single-anchor) host TCP-proxy workaround.
    private var tcpOwner: String?

    init(executableURL: URL, repoRoot: URL) {
        self.executableURL = executableURL
        self.repoRoot = repoRoot
    }

    var hasRunning: Bool { !running.isEmpty }

    // MARK: - Start

    func start(_ vm: VPhoneManagedVM) throws {
        guard !vm.runState.isActive else { return }
        guard running[vm.id] == nil else { return }

        let ssh = vm.sshForwardPref ?? Self.findFreePort() ?? 2222
        let rpc = vm.rpcForwardPref ?? Self.findFreePort() ?? 5910

        // Arbitrate the single-instance TCP workaround.
        var useTCP = false
        if vm.enableTCPWorkaround {
            if tcpOwner == nil {
                useTCP = true
                tcpOwner = vm.id
            } else {
                vm.log.appendChunk(
                    "[manager] another VM already holds the TCP workaround; starting without it\n"
                )
            }
        }

        var args = ["boot", "--config", "./config.plist"]
        args += ["--display-name", vm.displayName]
        if vm.softwareKeyboard { args.append("--software-keyboard") }
        args += ["--usbmux-forward", "\(ssh):22222"]
        args += ["--usbmux-forward", "\(rpc):5910"]
        if vm.socks5Port > 0 { args += ["--socks5-port", "\(vm.socks5Port)"] }
        if useTCP { args.append("--tcp-workaround") }
        args += vm.bootFlags

        let logURL = vm.dirURL
            .appendingPathComponent("logs")
            .appendingPathComponent("run-\(Self.timestamp()).log")
        guard let sink = VPhoneLogSink(fileURL: logURL) else {
            throw VPhoneManagerError.logOpenFailed(logURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = vm.dirURL
        var env = ProcessInfo.processInfo.environment
        // Let the in-child TCP-proxy elevation run passwordless (no TTY here).
        env["VPHONE_SUDO_NONINTERACTIVE"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let entry = Running(process: process, sink: sink, pipe: pipe)

        pipe.fileHandleForReading.readabilityHandler = { [weak vm] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            sink.write(data)
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in vm?.log.appendChunk(text) }
            }
        }

        process.terminationHandler = { [weak self, weak vm] proc in
            let code = proc.terminationStatus
            let signalled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in
                self?.handleExit(vmID: vm?.id, code: code, signalled: signalled)
            }
        }

        vm.log.appendChunk(
            "[manager] launching \(executableURL.lastPathComponent) \(args.joined(separator: " "))\n"
        )

        do {
            try process.run()
        } catch {
            sink.close()
            if tcpOwner == vm.id { tcpOwner = nil }
            throw error
        }

        running[vm.id] = entry
        vm.pid = process.processIdentifier
        vm.adopted = false
        vm.startedAt = Date()
        vm.lastExitCode = nil
        vm.lastMessage = nil
        vm.sshPort = ssh
        vm.rpcPort = rpc
        vm.usingTCPWorkaround = useTCP
        vm.runState = .starting
        vm.health = .starting
    }

    // MARK: - Stop

    /// Send SIGINT and return once the child has fully exited (so its disk /
    /// NVRAM / SEP locks are released before any restart).
    func stop(_ vm: VPhoneManagedVM) async {
        if let entry = running[vm.id] {
            entry.intentionalStop = true
            vm.runState = .stopping
            if entry.process.isRunning {
                entry.process.interrupt() // SIGINT → graceful teardown in the child
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if !entry.process.isRunning {
                    cont.resume()
                } else {
                    entry.exitWaiters.append(cont)
                }
            }
            return
        }

        // Adopted child (no Process handle) — signal by pid and poll for exit.
        guard let pid = vm.pid else {
            vm.runState = .stopped
            vm.health = .unknown
            return
        }
        vm.runState = .stopping
        kill(pid, SIGINT)
        for _ in 0 ..< 100 {
            if kill(pid, 0) != 0 { break } // gone
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if tcpOwner == vm.id { tcpOwner = nil }
        vm.pid = nil
        vm.adopted = false
        vm.runState = .stopped
        vm.health = .unknown
        vm.sshPort = nil
        vm.rpcPort = nil
    }

    private func handleExit(vmID: String?, code: Int32, signalled: Bool) {
        guard let vmID, let entry = running[vmID] else { return }
        entry.pipe.fileHandleForReading.readabilityHandler = nil
        entry.sink.close()
        running.removeValue(forKey: vmID)
        if tcpOwner == vmID { tcpOwner = nil }

        let waiters = entry.exitWaiters
        entry.exitWaiters = []
        for w in waiters { w.resume() }

        guard let vm = vmFinder?(vmID) else { return }
        vm.pid = nil
        vm.adopted = false
        vm.startedAt = nil
        vm.lastExitCode = code
        vm.health = .unknown
        vm.sshPort = nil
        vm.rpcPort = nil
        vm.usingTCPWorkaround = false

        if entry.intentionalStop || (!signalled && code == 0) {
            vm.runState = .stopped
            vm.lastMessage = entry.intentionalStop ? "Stopped" : "Guest powered off"
        } else {
            vm.runState = .failed
            vm.lastMessage = signalled
                ? "Child terminated by signal \(code)"
                : "Child exited with code \(code)"
        }
    }

    /// Resolves a VM id back to its live object. Injected by the model so the
    /// supervisor doesn't own the VM list.
    var vmFinder: ((String) -> VPhoneManagedVM?)?

    // MARK: - Adoption

    /// Mark VMs whose `vphone.sock` is live as already-running (adopted). Owned
    /// children are left untouched.
    func reconcileAdoptions(_ vms: [VPhoneManagedVM]) {
        for vm in vms {
            if running[vm.id] != nil { continue }
            let sockPath = vm.controlSocketURL.path
            if Self.socketIsListening(path: sockPath) {
                if !vm.runState.isActive {
                    vm.runState = .running
                    vm.adopted = true
                    vm.health = .unknown
                    vm.lastMessage = "Adopted (started outside the manager)"
                    vm.pid = Self.pidHolding(socketPath: sockPath)
                }
            } else if vm.adopted, vm.runState.isActive {
                // An adopted VM whose socket vanished has stopped.
                vm.runState = .stopped
                vm.adopted = false
                vm.pid = nil
                vm.health = .unknown
            }
        }
    }

    // MARK: - Log export

    /// Bundle a VM's run logs (and shared setup logs, if any) into a zip.
    func exportLogs(_ vm: VPhoneManagedVM, to destination: URL) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-logs-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let vmLogs = vm.dirURL.appendingPathComponent("logs")
        if fm.fileExists(atPath: vmLogs.path) {
            try? fm.copyItem(at: vmLogs, to: staging.appendingPathComponent("vm-logs"))
        }
        // The live buffer (includes the current, still-open run).
        let liveURL = staging.appendingPathComponent("live-console.log")
        try? vm.log.joined.data(using: .utf8)?.write(to: liveURL)

        let setupLogs = repoRoot.appendingPathComponent("setup_logs")
        if fm.fileExists(atPath: setupLogs.path) {
            try? fm.copyItem(at: setupLogs, to: staging.appendingPathComponent("setup_logs"))
        }

        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw VPhoneManagerError.exportFailed(Int(zip.terminationStatus))
        }
    }

    // MARK: - Teardown

    /// SIGINT every owned child (best-effort) on manager quit.
    func stopAllOwned() {
        for entry in running.values where entry.process.isRunning {
            entry.intentionalStop = true
            entry.process.interrupt()
        }
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Ask the kernel for a free loopback TCP port.
    nonisolated static func findFreePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: local.sin_port))
    }

    /// True if something is accepting on the given Unix socket path.
    nonisolated static func socketIsListening(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    /// True if a TCP listener is accepting on 127.0.0.1:<port>.
    nonisolated static func tcpPortListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// True if the privileged TCP-proxy relay (`vm_tproxy.py`) is running.
    nonisolated static func tproxyRelayRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "vm_tproxy.py"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Best-effort pid of the process holding a Unix socket (via `lsof -t`).
    nonisolated static func pidHolding(socketPath: String) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "--", socketPath]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { return pid }
        }
        return nil
    }
}
