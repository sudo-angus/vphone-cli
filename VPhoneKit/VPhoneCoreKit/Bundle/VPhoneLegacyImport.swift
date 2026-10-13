import Darwin
import Foundation
import Virtualization

/// Copies a stopped legacy device; never restores it or generates an identity.
public enum VPhoneLegacyImport {
    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Decode in memory. The source config is never rewritten.
    public static func manifest(from data: Data, hardwareKeyboard: Bool = false) throws -> VPhoneVirtualMachineManifest {
        guard var record = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              record["schemaVersion"] == nil,
              let identity = record["machineIdentifier"] as? Data,
              VZMacMachineIdentifier(dataRepresentation: identity) != nil
        else { throw Refusal("Import requires an unversioned legacy config with a valid existing machineIdentifier.") }
        record["schemaVersion"] = 2
        record["legacyGuestEnvironment"] = true
        record["paravirtualAcceleratorsEnabled"] = false
        record["hardwareKeyboardEnabled"] = hardwareKeyboard
        let converted = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let manifest = try PropertyListDecoder().decode(VPhoneVirtualMachineManifest.self, from: converted)
        guard manifest.machineIdentifier == identity, manifest.romImages != nil else {
            throw Refusal("Legacy import must retain the existing identity and both ROM files.")
        }
        for (_, name) in manifest.bundleFileNames {
            guard VPhoneVirtualMachineManifest.isPlainFileName(name) else { throw Refusal("Invalid legacy VM file name: \(name)") }
        }
        return manifest
    }

    public static func copy(from source: URL, named name: String, into library: VPhoneLibrary,
                            hardwareKeyboard: Bool = false, socks5HostPort: Int? = nil) throws -> VPhoneBundle {
        try VPhoneBundleOperations.requireValidName(name)
        if let port = socks5HostPort, !(1024 ... 65535).contains(port) { throw Refusal("SOCKS5 host port must be 1024...65535.") }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let config = source.appendingPathComponent("config.plist")
        guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: config) else { throw Refusal("Legacy config is missing.") }
        let originalData = try Data(contentsOf: config)
        var converted = try manifest(from: originalData, hardwareKeyboard: hardwareKeyboard)
        if let port = socks5HostPort {
            guard converted.networkConfig.mode == .nat else { throw Refusal("Legacy direct SOCKS5 import requires the original NAT network.") }
            var forwards = converted.networkConfig.portForwards ?? []
            forwards.append(.init(hostPort: port, guestPort: 1080))
            converted = converted.updating(networkConfig: converted.networkConfig.with(portForwards: forwards))
        }
        for (field, file) in converted.bundleFileNames {
            guard try VPhoneVirtualMachineManifest.requireRegularFileIfPresent(at: source.appendingPathComponent(file)) else {
                throw Refusal("Legacy VM is missing \(field): \(file). Refusing to create replacement storage.")
            }
        }
        let original = VPhoneBundle(url: source, manifest: converted)
        try VPhoneBundleActivity.requireStopped(original, waitingForReaders: 2)
        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        let destination = library.url(forName: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VPhoneLibraryError.alreadyExists(name: name) }
        let staging = library.root.appendingPathComponent(".legacy-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        // Clone only device state and ROMs. Build caches and old GUI logs stay
        // with the original. APFS CoW keeps the 128 GiB sparse disk sparse.
        for file in Set(converted.bundleFileNames.map(\.1)) {
            guard clonefile(source.appendingPathComponent(file).path, staging.appendingPathComponent(file).path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw Refusal("APFS clone of \(file) failed (errno \(errno)); the original VM was not modified.")
            }
        }
        try VPhoneBundleActivity.requireStopped(original, waitingForReaders: 2)
        guard try Data(contentsOf: config) == originalData else { throw Refusal("Source configuration changed during import.") }
        try originalData.write(to: staging.appendingPathComponent("config.legacy.plist"), options: .atomic)
        try converted.write(to: staging.appendingPathComponent("config.plist"))
        let receipt = try JSONSerialization.data(withJSONObject: ["source": source.path, "identityPreserved": true], options: [.prettyPrinted])
        try receipt.write(to: staging.appendingPathComponent("legacy-import.json"), options: .atomic)
        _ = try VPhoneBundle.load(at: staging)
        // Publish atomically, without replacing a concurrently created machine.
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw Refusal("Cannot publish imported VM (errno \(errno)); no existing machine was replaced.")
        }
        return try VPhoneBundle.load(at: destination)
    }

    /// Same-identity copies are alternatives, never two independent devices.
    /// Check the original at every launch, including direct vphone-vm calls.
    public static func requireSourceStopped(for bundle: VPhoneBundle) throws {
        guard bundle.manifest.legacyGuestEnvironment == true else { return }
        let receiptURL = bundle.url.appendingPathComponent("legacy-import.json")
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
        guard let path = receipt?["source"] as? String else { throw Refusal("Invalid legacy import receipt.") }
        let source = URL(fileURLWithPath: path)
        let config = source.appendingPathComponent("config.plist")
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        let sourceData = try Data(contentsOf: config)
        let sourceManifest: VPhoneVirtualMachineManifest
        if let record = try PropertyListSerialization.propertyList(from: sourceData, format: nil) as? [String: Any], record["schemaVersion"] == nil {
            sourceManifest = try manifest(from: sourceData)
        } else { sourceManifest = try VPhoneVirtualMachineManifest.load(from: config) }
        if sourceManifest.machineIdentifier == bundle.manifest.machineIdentifier {
            try VPhoneBundleActivity.requireStopped(VPhoneBundle(url: source, manifest: sourceManifest), waitingForReaders: 2)
        }
    }
}
