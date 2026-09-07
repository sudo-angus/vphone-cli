import Foundation
import Observation

/// State for the "New VM" wizard: the configuration the user picks before the
/// orchestration engine drives `setup_machine.sh`. New VMs are created in
/// `vms/<slug>/` so the existing `vm/` is never touched.
@Observable
@MainActor
final class VPhoneCreateModel: Identifiable {
    nonisolated let id = UUID()

    enum Variant: String, CaseIterable, Identifiable, Sendable {
        case regular, dev, jb, exp, less
        var id: String { rawValue }

        var label: String {
            switch self {
            case .regular: "Regular"
            case .dev: "Development"
            case .jb: "Jailbreak"
            case .exp: "Experimental"
            case .less: "Patchless"
            }
        }

        var blurb: String {
            switch self {
            case .regular: "Standard CFW. Direct console, SSH after setup."
            case .dev: "Regular + rpcserver / dev TXM bypasses."
            case .jb: "Sileo, TrollStore, apt — full security bypass."
            case .exp: "Jailbreak + anti-VM research patches (hv_vmm rename, DT identity)."
            case .less: "Minimal patches; needs the broader AMFI bypass."
            }
        }

        /// The `make` flag that selects this variant (nil for regular).
        var makeFlag: String? {
            switch self {
            case .regular: nil
            case .dev: "DEV=1"
            case .jb: "JB=1"
            case .exp: "EXP=1"
            case .less: "LESS=1"
            }
        }
    }

    let registry: VPhoneVMRegistry
    let privilege: VPhonePrivilege
    let catalog: VPhoneMakeFirmwareCatalog
    let engine = VPhoneCreateEngine()

    var name = "vPhone"
    var variant: Variant = .dev
    var cpu = 6
    var memoryMB = 8192
    var diskGB = 128
    var selectedFirmware: VPhoneFirmware?

    var error: String?

    init(registry: VPhoneVMRegistry, privilege: VPhonePrivilege) {
        self.registry = registry
        self.privilege = privilege
        catalog = VPhoneMakeFirmwareCatalog(repoRoot: registry.repoRoot)
    }

    /// Authorize the create-time `hdiutil` elevation if needed, then kick off
    /// the orchestration engine.
    func beginCreate() async {
        if !privilege.canCreatePasswordless() {
            do {
                try await privilege.authorize()
            } catch VPhoneManagerError.authorizationCancelled {
                error = "Creating a VM needs admin authorization (it mounts the CFW image as root)."
                return
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        engine.start(model: self, repoRoot: registry.repoRoot)
    }

    /// Filesystem-safe directory name derived from the display name.
    var slug: String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "vphone" : trimmed
    }

    var targetDir: URL { registry.libraryRoot.appendingPathComponent(slug) }

    var targetExists: Bool {
        FileManager.default.fileExists(atPath: targetDir.path)
            || FileManager.default.fileExists(atPath: registry.repoRoot.appendingPathComponent("vm/\(slug)").path)
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedFirmware != nil
            && !targetExists
    }

    func loadFirmwares() async {
        await catalog.load()
        if selectedFirmware == nil { selectedFirmware = defaultFirmware() }
    }

    /// Default to a firmware the user already has a device on (cheapest, and
    /// already proven on this Mac): the cached build the most existing VMs use.
    /// Falls back to any cached build, then the highest Supported, then anything.
    private func defaultFirmware() -> VPhoneFirmware? {
        let fws = catalog.firmwares
        let installed = registry.installedBuildCounts()
        let onExistingVMs = fws
            .filter { $0.ipswCached && (installed[$0.build] ?? 0) > 0 }
            .max { (installed[$0.build] ?? 0) < (installed[$1.build] ?? 0) }
        return onExistingVMs
            ?? fws.first { $0.ipswCached && $0.isSupported }
            ?? fws.first { $0.ipswCached }
            ?? fws.first { $0.isSupported }
            ?? fws.first
    }
}
