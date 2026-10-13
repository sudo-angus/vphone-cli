import ArgumentParser
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineImportLegacyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-legacy",
        abstract: "Import a stopped 1.x VM directory with its original device identity (APFS copy)",
    )
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "Existing legacy VM directory") var source: String
    @Option(name: .shortAndLong, help: "Name of the imported copy") var name: String
    @Flag(help: "Keep the USB hardware keyboard; default uses the software keyboard") var hardwareKeyboard = false

    @Option(help: "Forward a loopback host TCP port to the existing guest SOCKS5 service on 1080") var socks5HostPort: Int?

    func run() throws {
        let imported = try VPhoneLegacyImport.copy(
            from: URL(fileURLWithPath: source), named: name, into: lib.library,
            hardwareKeyboard: hardwareKeyboard, socks5HostPort: socks5HostPort,
        )
        print("imported \(imported.name): original disk, NVRAM, SEP, ROMs and machineIdentifier preserved")
        print("The source is unchanged. Do not run the source and this copy simultaneously.")
    }
}
