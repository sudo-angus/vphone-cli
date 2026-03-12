import ArgumentParser
import Foundation

struct SendRamdiskCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-ramdisk",
        abstract: "Send signed ramdisk components to a device in DFU/recovery mode"
    )

    @Option(name: .customLong("ramdisk-dir"), help: "Path to the Ramdisk directory.", transform: URL.init(fileURLWithPath:))
    var ramdiskDirectory: URL = URL(fileURLWithPath: "Ramdisk", isDirectory: true)

    @Option(name: .customLong("ecid"), help: "Optional ECID selector.")
    var ecid: String?

    @Option(name: .customLong("udid"), help: "Optional UDID for logging context.")
    var udid: String?

    mutating func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let udid = udid ?? env["RAMDISK_UDID"] ?? env["RESTORE_UDID"]
        let ecid = try normalizedECID(ecid ?? env["RAMDISK_ECID"])

        print("[*] Identity context for ramdisk_send:")
        print("    UDID: \(udid ?? "<unset>")")
        print("    ECID: \(ecid ?? "<unset>")")

        guard FileManager.default.fileExists(atPath: ramdiskDirectory.path) else {
            throw ValidationError("Ramdisk directory not found: \(ramdiskDirectory.path). Run 'make ramdisk_build' first.")
        }

        let kernelURL: URL = {
            let ramdiskKernel = ramdiskDirectory.appendingPathComponent("krnl.ramdisk.img4")
            if FileManager.default.fileExists(atPath: ramdiskKernel.path) {
                print("  [*] Using ramdisk kernel variant: \(ramdiskKernel.lastPathComponent)")
                return ramdiskKernel
            }
            return ramdiskDirectory.appendingPathComponent("krnl.img4")
        }()
        try VPhoneHost.requireFile(kernelURL)

        print("[*] Sending ramdisk from \(ramdiskDirectory.path) ...")
        let numericECID = try normalizedECIDValue(ecid)
        print("[*] Using libirecovery transport")

        print("  [*] Sending iBSS in DFU mode...")
        try VPhoneIRecovery.sendDFUFile(
            path: ramdiskDirectory.appendingPathComponent("iBSS.vresearch101.RELEASE.img4").path,
            ecid: numericECID
        )

        print("  [*] Waiting for iBSS transition into recovery mode...")
        try VPhoneIRecovery.waitForRecovery(ecid: numericECID)

        print("  [2/8] Loading iBEC.vresearch101.RELEASE.img4...")
        let iBECSession = try VPhoneIRecovery.openRecoverySession(ecid: numericECID)
        defer { iBECSession.close() }
        try iBECSession.sendFile(path: ramdiskDirectory.appendingPathComponent("iBEC.vresearch101.RELEASE.img4").path)
        try iBECSession.sendCommandBreq("go")
        try iBECSession.usbControlTransfer(allowFailure: true)

        print("  [*] Waiting for post-iBEC recovery mode...")
        try VPhoneIRecovery.waitForRecovery(ecid: numericECID)

        let recoverySession = try VPhoneIRecovery.openRecoverySession(ecid: numericECID)
        defer { recoverySession.close() }
        try sendViaRecoverySession(recoverySession, named: "sptm.vresearch1.release.img4", step: "3/8", command: "firmware")
        try sendViaRecoverySession(recoverySession, named: "txm.img4", step: "4/8", command: "firmware")
        try sendViaRecoverySession(recoverySession, named: "trustcache.img4", step: "5/8", command: "firmware")
        try sendViaRecoverySession(recoverySession, named: "ramdisk.img4", step: "6/8", command: nil)
        try recoverySession.sendCommand("getenv ramdisk-delay")
        try recoverySession.sendCommand("ramdisk")
        try await Task.sleep(for: .seconds(2))
        try sendViaRecoverySession(recoverySession, named: "DeviceTree.vphone600ap.img4", step: "7/8", command: "devicetree")
        try sendViaRecoverySession(recoverySession, named: "sep-firmware.vresearch101.RELEASE.img4", step: "8/8", command: "rsepfirmware")

        print("  [*] Booting kernel...")
        try recoverySession.sendFile(path: kernelURL.path)
        try recoverySession.usbControlTransfer(allowFailure: true)
        try recoverySession.sendCommandBreq("bootx")

        print("[+] Boot sequence complete. Device should be booting into ramdisk.")
    }
}

private extension SendRamdiskCLI {
    func normalizedECID(_ rawValue: String?) throws -> String? {
        guard var rawValue, !rawValue.isEmpty else {
            return nil
        }
        rawValue = rawValue.replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
        guard rawValue.range(of: #"^[0-9A-Fa-f]{1,16}$"#, options: .regularExpression) != nil else {
            throw ValidationError("Invalid ECID: \(rawValue)")
        }
        return "0x\(rawValue.uppercased())"
    }

    func normalizedECIDValue(_ rawValue: String?) throws -> UInt64? {
        guard let normalized = try normalizedECID(rawValue) else {
            return nil
        }
        return UInt64(normalized.dropFirst(2), radix: 16)
    }

    func sendViaRecoverySession(_ session: RecoverySession, named fileName: String, step: String, command: String?) throws {
        let fileURL = ramdiskDirectory.appendingPathComponent(fileName)
        try VPhoneHost.requireFile(fileURL)
        print("  [\(step)] Loading \(fileName)...")
        try session.sendFile(path: fileURL.path)
        if let command {
            try session.sendCommand(command)
        }
    }
}
