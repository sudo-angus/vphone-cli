import Foundation

/// Manager-owned sidecar metadata for a VM directory (`vphone-meta.json`).
///
/// `config.plist` is the boot manifest and is read/written by the boot path; it
/// has no place for human-facing or workflow fields. This file holds what the
/// manager needs and the manifest does not: a display name, the firmware
/// variant the VM was built as, its iOS version label, when it was created, and
/// per-VM default boot flags. All fields are optional so a VM with no sidecar
/// (e.g. the legacy `vm/`) still loads with sensible fallbacks.
struct VPhoneVMMeta: Codable {
    var displayName: String?
    var variant: String?
    var iosVersion: String?
    var createdAt: Date?
    /// Extra raw boot flags appended after the structured options (escape hatch).
    var bootFlags: [String]?
    /// Whether this VM should boot with the host TCP-proxy workaround.
    var enableTCPWorkaround: Bool?
    /// Drop the USB keyboard so the iOS software keyboard shows (boot.sh default).
    var softwareKeyboard: Bool?
    /// Expose the guest network as a SOCKS5 proxy on 127.0.0.1:<port> (0 = off).
    var socks5Port: Int?
    /// Fixed local port for the usbmux SSH forward (→ guest 22222); nil = auto.
    var sshForwardPort: Int?
    /// Fixed local port for the usbmux RPC forward (→ guest 5910); nil = auto.
    var rpcForwardPort: Int?
    var notes: String?

    static let fileName = "vphone-meta.json"

    /// Load the sidecar from a VM directory, or nil if absent/unreadable.
    static func load(fromVMDir dir: URL) -> VPhoneVMMeta? {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VPhoneVMMeta.self, from: data)
    }

    /// Persist the sidecar into a VM directory.
    func write(toVMDir dir: URL) throws {
        let url = dir.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url)
    }
}
