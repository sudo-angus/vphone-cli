import ArgumentParser
import Darwin
import Foundation

struct SetupMachineCLI: AsyncParsableCommand {
    enum Variant: String, ExpressibleByArgument {
        case regular
        case dev
        case jb
    }

    static let configuration = CommandConfiguration(
        commandName: "setup-machine",
        abstract: "Run the first-boot automation pipeline without shell wrappers"
    )

    @Option(help: "Project root", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    @Option(help: "VM directory")
    var vmDirectory: String = ProcessInfo.processInfo.environment["VM_DIR"] ?? "vm"

    @Option(help: "Automation variant")
    var variant: Variant = {
        let env = ProcessInfo.processInfo.environment
        if ["1", "true", "yes"].contains(env["JB"]?.lowercased() ?? "") { return .jb }
        if ["1", "true", "yes"].contains(env["DEV"]?.lowercased() ?? "") { return .dev }
        return .regular
    }()

    @Flag(help: "Skip setup_tools/build stage")
    var skipProjectSetup: Bool = {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["SKIP_PROJECT_SETUP"]?.lowercased() ?? "")
    }()

    @Flag(help: "Auto-continue first boot and final boot analysis")
    var nonInteractive: Bool = {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment["NONE_INTERACTIVE"]?.lowercased() ?? "")
    }()

    mutating func run() async throws {
        let runner = try SetupMachineRunner(
            projectRoot: projectRoot.standardizedFileURL,
            vmDirectoryName: vmDirectory,
            variant: variant,
            skipProjectSetup: skipProjectSetup,
            nonInteractive: nonInteractive
        )
        try await runner.run()
    }
}

private struct SetupMachineRunner {
    let projectRoot: URL
    let vmDirectoryName: String
    let variant: SetupMachineCLI.Variant
    let skipProjectSetup: Bool
    let nonInteractive: Bool

    let logDirectory: URL
    let bootDFULog: URL
    let bootLog: URL

    init(projectRoot: URL, vmDirectoryName: String, variant: SetupMachineCLI.Variant, skipProjectSetup: Bool, nonInteractive: Bool) throws {
        self.projectRoot = projectRoot
        self.vmDirectoryName = vmDirectoryName
        self.variant = variant
        self.skipProjectSetup = skipProjectSetup
        self.nonInteractive = nonInteractive
        logDirectory = projectRoot.appendingPathComponent("setup_logs", isDirectory: true)
        bootDFULog = logDirectory.appendingPathComponent("boot_dfu.log")
        bootLog = logDirectory.appendingPathComponent("boot.log")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    var fwPatchTarget: String {
        switch variant {
        case .regular: "fw_patch"
        case .dev: "fw_patch_dev"
        case .jb: "fw_patch_jb"
        }
    }

    var cfwInstallTarget: String {
        switch variant {
        case .regular: "cfw_install"
        case .dev: "cfw_install_dev"
        case .jb: "cfw_install_jb"
        }
    }

    func run() async throws {
        print("[*] setup-machine variant=\(variant.rawValue) skipProjectSetup=\(skipProjectSetup) nonInteractive=\(nonInteractive)")

        if !skipProjectSetup {
            try await runMake("Project setup", args: ["setup_tools"])
            try await runMake("Project setup", args: ["build"])
        } else {
            print("[*] Skipping setup_tools/build")
        }

        try await runMake("Firmware prep", args: ["vm_new"])
        try await runMake("Firmware prep", args: ["fw_prepare"])
        try await runMake("Firmware patch", args: [fwPatchTarget])

        let dfu = try startBackgroundMake(target: "boot_dfu", logURL: bootDFULog)
        defer { dfu.terminate() }

        let identity = try await waitForIdentity()
        try await runMake("Restore", args: ["restore_get_shsh", "RESTORE_UDID=\(identity.udid)", "RESTORE_ECID=0x\(identity.ecid)"])
        try await runMake("Restore", args: ["restore", "RESTORE_UDID=\(identity.udid)", "RESTORE_ECID=0x\(identity.ecid)"])

        dfu.terminate()
        try await Task.sleep(for: .seconds(5))

        let ramdiskDFU = try startBackgroundMake(target: "boot_dfu", logURL: bootDFULog)
        defer { ramdiskDFU.terminate() }

        let ramdiskIdentity = try await waitForIdentity()
        try await runMake("Ramdisk", args: ["ramdisk_build", "RAMDISK_UDID=\(ramdiskIdentity.udid)"])
        try await runMake("Ramdisk", args: ["ramdisk_send", "RAMDISK_ECID=0x\(ramdiskIdentity.ecid)", "RAMDISK_UDID=\(ramdiskIdentity.udid)"])

        let forwardedPort = try chooseRandomPort()
        let usbmux = try startUSBMuxForward(localPort: forwardedPort, serial: ramdiskIdentity.udid)
        defer { usbmux.terminate() }

        try await waitForSSH(port: forwardedPort)
        try await runMake("CFW install", args: [cfwInstallTarget, "SSH_PORT=\(forwardedPort)"])

        ramdiskDFU.terminate()
        usbmux.terminate()

        if nonInteractive {
            try await runNonInteractiveFirstBoot()
            try await runBootAnalysis()
        }

        if variant == .jb {
            print("[*] JB finalization will run automatically on first normal boot via /cores/vphone_jb_setup.sh.")
        }
        print("[+] setup-machine complete")
    }

    func runMake(_ label: String, args: [String]) async throws {
        print("")
        print("=== \(label) ===")
        let result = try await VPhoneHost.runCommand("make", arguments: args, environment: ["VM_DIR": vmDirectoryName], requireSuccess: true)
        if !result.standardOutput.isEmpty { print(result.standardOutput) }
        if !result.standardError.isEmpty { print(result.standardError) }
    }

    func waitForIdentity(timeout: TimeInterval = 30) async throws -> (udid: String, ecid: String) {
        let predictionFile = projectRoot.appendingPathComponent(vmDirectoryName, isDirectory: true).appendingPathComponent("udid-prediction.txt")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: predictionFile.path) {
                let text = try String(contentsOf: predictionFile, encoding: .utf8)
                var udid = ""
                var ecid = ""
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "UDID": udid = parts[1].uppercased()
                    case "ECID": ecid = parts[1].replacingOccurrences(of: "0x", with: "").uppercased()
                    default: break
                    }
                }
                if !udid.isEmpty && !ecid.isEmpty {
                    print("[+] Device identity loaded: UDID=\(udid) ECID=0x\(ecid)")
                    return (udid, ecid)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ValidationError("Timed out waiting for udid-prediction.txt")
    }

    func startBackgroundMake(target: String, logURL: URL) throws -> ManagedProcess {
        try Data().write(to: logURL)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: resolveCommand("make") ?? "/usr/bin/make")
        process.arguments = [target]
        process.environment = ProcessInfo.processInfo.environment.merging(["VM_DIR": vmDirectoryName]) { _, new in new }
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return ManagedProcess(process: process, logHandle: logHandle)
    }

    func startUSBMuxForward(localPort: Int, serial: String) throws -> ManagedProcess {
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = projectRoot.appendingPathComponent(".build/debug/vphone-cli")
        process.arguments = ["usbmux-forward", "--local-port", "\(localPort)", "--serial", serial, "--remote-port", "22"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return ManagedProcess(process: process, logHandle: nil)
    }

    func waitForSSH(port: Int, timeout: TimeInterval = 90) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await VPhoneHost.runCommand(
                "ssh",
                arguments: [
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "PreferredAuthentications=password",
                    "-o", "NumberOfPasswordPrompts=1",
                    "-o", "ConnectTimeout=5",
                    "-q",
                    "-p", "\(port)",
                    "root@127.0.0.1",
                    "echo ready",
                ],
                environment: VPhoneHost.sshAskpassEnvironment(password: "alpine"),
                requireSuccess: false
            )
            if result.terminationStatus.isSuccess { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw ValidationError("Timed out waiting for ramdisk SSH on port \(port)")
    }

    func runNonInteractiveFirstBoot() async throws {
        try Data().write(to: bootLog)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: resolveCommand("make") ?? "/usr/bin/make")
        process.arguments = ["boot", "VM_DIR=\(vmDirectoryName)"]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let logHandle = try FileHandle(forWritingTo: bootLog)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        try await waitForBootPrompt(in: bootLog)
        let commands = [
            "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'",
            "cp /iosbinpack64/etc/profile /var/profile",
            "cp /iosbinpack64/etc/motd /var/motd",
            "mkdir -p /var/dropbear",
            "dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key",
            "dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key",
            "shutdown -h now",
        ]
        for command in commands {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        }
        process.waitUntilExit()
        try logHandle.close()
    }

    func runBootAnalysis() async throws {
        try Data().write(to: bootLog)
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: resolveCommand("make") ?? "/usr/bin/make")
        process.arguments = ["boot", "VM_DIR=\(vmDirectoryName)"]
        let logHandle = try FileHandle(forWritingTo: bootLog)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? logHandle.close()
        }
        try await waitForBootPrompt(in: bootLog)
        process.terminate()
    }

    func waitForBootPrompt(in logURL: URL, timeout: TimeInterval = 300) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if text.range(of: "bash-", options: .regularExpression) != nil { return }
            if text.range(of: "panic|kernel panic|panic\\.apple\\.com|stackshot succeeded", options: .regularExpression) != nil {
                throw ValidationError("Panic detected during boot")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ValidationError("Timed out waiting for first boot prompt")
    }

    func chooseRandomPort() throws -> Int {
        for _ in 0 ..< 200 {
            let port = Int.random(in: 20_000 ... 60_000)
            if isPortFree(port) { return port }
        }
        throw ValidationError("Failed to allocate a random local SSH forward port")
    }

    func isPortFree(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func resolveCommand(_ command: String) -> String? {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

private final class ManagedProcess {
    let process: Process
    let logHandle: FileHandle?

    init(process: Process, logHandle: FileHandle?) {
        self.process = process
        self.logHandle = logHandle
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? logHandle?.close()
    }
}
