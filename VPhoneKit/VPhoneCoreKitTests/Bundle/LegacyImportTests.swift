import Darwin
import Foundation
import Testing
import Virtualization
@testable import VPhoneCoreKit

struct LegacyImportTests {
    private func fixture() throws -> (URL, URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
            cpuCount: 4, memorySize: 4 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "rom.bin", avpSEPBooter: "sep-rom.bin"))
        var raw = try #require(PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(manifest), format: nil) as? [String: Any])
        raw.removeValue(forKey: "schemaVersion")
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        try data.write(to: source.appendingPathComponent("config.plist"))
        for (_, file) in manifest.bundleFileNames { try Data("original \(file)".utf8).write(to: source.appendingPathComponent(file)) }
        return (root, source, data)
    }

    @Test func `APFS import preserves storage identity source and compatibility settings`() throws {
        let (root, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try VPhoneLegacyImport.copy(from: source, named: "kept", into: VPhoneLibrary(root: root.appendingPathComponent("library")), socks5HostPort: 11080)
        #expect(try Data(contentsOf: source.appendingPathComponent("config.plist")) == original)
        #expect(try Data(contentsOf: imported.url.appendingPathComponent("config.legacy.plist")) == original)
        let old = try VPhoneLegacyImport.manifest(from: original)
        #expect(imported.manifest.machineIdentifier == old.machineIdentifier)
        #expect(imported.manifest.legacyGuestEnvironment == true)
        #expect(imported.manifest.paravirtualAcceleratorsEnabled == false)
        #expect(imported.manifest.usesHardwareKeyboard == false)
        #expect(imported.manifest.networkConfig.mode == .nat)
        #expect(imported.manifest.networkConfig.portForwards?.first?.hostPort == 11080)
        for (_, file) in imported.manifest.bundleFileNames {
            #expect(try Data(contentsOf: imported.url.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file)))
        }
        let edited = imported.manifest.updating(cpuCount: 2).updating(guestDevice: .default)
        #expect(edited.legacyGuestEnvironment == true)
        #expect(edited.paravirtualAcceleratorsEnabled == false)
        try VPhoneLegacyImport.requireSourceStopped(for: imported)
        // Even a read-only holder of the old state prevents a same-identity boot.
        let fd = open(source.appendingPathComponent(old.sepStorage).path, O_RDONLY)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        #expect(throws: (any Error).self) { try VPhoneLegacyImport.requireSourceStopped(for: imported) }
    }

    @Test func `missing storage and invalid identities refuse without creating a device`() throws {
        let (root, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VPhoneLibrary(root: root.appendingPathComponent("library"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("SEPStorage"))
        #expect(throws: (any Error).self) { _ = try VPhoneLegacyImport.copy(from: source, named: "missing", into: library) }
        #expect(!FileManager.default.fileExists(atPath: library.url(forName: "missing").path))
        for invalid in [Data(), Data([1, 2, 3])] {
            var raw = try #require(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
            raw["machineIdentifier"] = invalid
            let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
            #expect(throws: VPhoneLegacyImport.Refusal.self) { _ = try VPhoneLegacyImport.manifest(from: data) }
        }
        #expect(try Data(contentsOf: source.appendingPathComponent("config.plist")) == original)
    }

    @Test func `existing destination and paths outside the source refuse`() throws {
        let (root, source, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VPhoneLibrary(root: root.appendingPathComponent("library"))
        try FileManager.default.createDirectory(at: library.url(forName: "existing"), withIntermediateDirectories: true)
        let marker = library.url(forName: "existing").appendingPathComponent("keep")
        try Data([9]).write(to: marker)
        #expect(throws: VPhoneLibraryError.self) { _ = try VPhoneLegacyImport.copy(from: source, named: "existing", into: library) }
        #expect(try Data(contentsOf: marker) == Data([9]))
        var raw = try #require(PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        raw["diskImage"] = "../elsewhere"
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
        #expect(throws: VPhoneLegacyImport.Refusal.self) { _ = try VPhoneLegacyImport.manifest(from: data) }
    }
}
