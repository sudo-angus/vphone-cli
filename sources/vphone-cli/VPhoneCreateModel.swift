import Foundation
import Observation
import VPhoneCore

/// State for the "New VM" wizard: the configuration the user picks before the
/// engine drives `vphone-cli vm create`. New VMs land in the same library the
/// CLI uses (`~/.vphone/VMs` unless overridden), so `vm list` / `vm launch` and
/// the manager see one set of bundles.
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

        /// Variants the wizard offers. `less` has to run as root end to end
        /// (`sudo vphone-cli vm create -V less …`), which a GUI shouldn't do.
        static let wizardChoices: [Variant] = [.regular, .dev, .jb, .exp]
    }

    let registry: VPhoneVMRegistry
    let privilege: VPhonePrivilege
    let catalog: VPhoneFirmwareChoices
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
        catalog = VPhoneFirmwareChoices(repoRoot: registry.repoRoot)
    }

    /// `vm create` restores and first-boots through the entitled boot binary,
    /// which AMFI only admits while amfidont is up — the same precondition as
    /// starting a VM. Root for the CFW host-mount comes from macOS's own
    /// authentication dialog inside the child (`--root-popup`), not from here.
    func beginCreate() async {
        guard privilege.authStatus() == .authorized else {
            error = "Authorize admin first (top of the window): the restore and first boot run the entitled boot binary, which needs the AMFI bypass."
            return
        }
        switch await privilege.ensureAmfidont() {
        case .running, .started:
            break
        case .needsAuthorization:
            error = "The AMFI bypass can't start without a password. Remove and redo “Authorize admin”, then retry."
            return
        case .unavailable:
            error = "amfidont isn't importable by any python3. Install it (xcrun python3 -m pip install amfidont) and retry."
            return
        case let .failed(message):
            error = "Could not start the AMFI bypass: \(message)"
            return
        }
        engine.start(
            model: self,
            registry: registry,
            executable: VPhoneVMRegistry.locateBootBinary(repoRoot: registry.repoRoot)
        )
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

    var targetDisplayPath: String { VPhoneVMRegistry.displayPath(targetDir) }

    var targetExists: Bool {
        FileManager.default.fileExists(atPath: targetDir.path)
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
    /// Falls back to any cached build, then the highest tested, then anything.
    private func defaultFirmware() -> VPhoneFirmware? {
        let fws = catalog.firmwares
        let installed = registry.installedBuildCounts()
        let onExistingVMs = fws
            .filter { $0.ipswCached && (installed[$0.build] ?? 0) > 0 }
            .max { (installed[$0.build] ?? 0) < (installed[$1.build] ?? 0) }
        return onExistingVMs
            ?? fws.last { $0.ipswCached && $0.isSupported }
            ?? fws.last { $0.ipswCached }
            ?? fws.last { $0.isSupported }
            ?? fws.last
    }
}
