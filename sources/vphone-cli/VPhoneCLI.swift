import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [
            VPhoneBootCLI.self, VPhoneManageCLI.self, PatchFirmwareCLI.self, PatchComponentCLI.self, VPhoneVMCommand.self,
            VPhoneFWCommand.self, VPhoneRestoreCommand.self, VPhoneCFWCommand.self, VPhoneSetupCommand.self,
        ],
        defaultSubcommand: VPhoneBootCLI.self
    )
}

struct VPhoneBootCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it from a manifest plist that describes all paths and hardware.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled
          - Signed with vphone entitlements (done automatically by wrapper script)

        Example:
          vphone-cli --config ./config.plist
        """
    )

    @Option(
        name: .shortAndLong,
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL

    @Flag(name: .shortAndLong, help: "Boot into DFU mode")
    var dfu: Bool = false

    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar")
    var headless: Bool = false

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to execute.")
    var variant: PatchFirmwareCLI.VariantOption = .regular

    @Option(
        name: .customLong("display-name"),
        help: "Human-facing name shown in the VM window title (defaults to the VM directory name)."
    )
    var displayName: String?

    @Flag(help: "Do not attach a USB keyboard device so the iOS software keyboard appears")
    var softwareKeyboard: Bool = false

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:)
    )
    var installIPA: URL?
    
    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned usage (patchless-only).")
    var noVphoned: Bool = false

    @Flag(
        name: .customLong("tcp-workaround"),
        help: """
        Start the host-side transparent TCP proxy workaround for hosts where a \
        VPN / traffic-forwarding agent breaks guest outbound TCP under \
        VZNATNetworkDeviceAttachment. Triggers a one-time admin password \
        prompt; the proxy runs only for the lifetime of this boot. \
        Unavailable with --dfu.
        """
    )
    var tcpWorkaround: Bool = false

    @Option(
        name: .customLong("socks5-port"),
        help: """
        Expose the guest's network as a SOCKS5 proxy on 127.0.0.1:<port>. \
        Use 0 (default) to disable. The host bridge is a transparent byte \
        pump; SOCKS5 (incl. DNS) runs in the guest, so any active iOS VPN \
        routes are picked up automatically. Unavailable with --dfu.
        """
    )
    var socks5Port: Int = 0

    @Option(
        name: .customLong("usbmux-forward"),
        help: """
        Forward a local TCP port to a guest TCP port through native usbmux. \
        Repeatable. Format: <local-port>:<guest-port>, e.g. 2222:22222 or 5910:5910. \
        Unavailable with --dfu.
        """
    )
    var usbmuxForwards: [VPhoneUSBMuxForwardSpec] = []

    @Option(
        name: .customLong("usbmux-udid"),
        help: "Override the usbmux target UDID for integrated native port forwarding."
    )
    var usbmuxUDID: String?

    /// DFU mode is always headless.
    var noGraphics: Bool {
        dfu || headless
    }

    var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    mutating func validate() throws {
        if dfu, tcpWorkaround {
            throw ValidationError(
                "`--tcp-workaround` is unavailable with `--dfu` because DFU mode has no guest network."
            )
        }

        if socks5Port != 0 {
            if dfu {
                throw ValidationError(
                    "`--socks5-port` is unavailable with `--dfu` because DFU mode does not start vphoned."
                )
            }
            if !(1 ... 65535).contains(socks5Port) {
                throw ValidationError("`--socks5-port` must be 0 (disabled) or 1...65535")
            }
        }

        if !usbmuxForwards.isEmpty {
            if dfu {
                throw ValidationError(
                    "`--usbmux-forward` is unavailable with `--dfu` because DFU mode has no usbmux TCP services."
                )
            }
            var localPorts = Set<Int>()
            for forward in usbmuxForwards {
                guard localPorts.insert(forward.localPort).inserted else {
                    throw ValidationError("duplicate `--usbmux-forward` local port: \(forward.localPort)")
                }
            }
        }

        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)"
            )
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)"
            )
        }
    }

    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        // Prefer the explicit name the manager passes; otherwise fall back to the
        // VM directory name so a direct `make boot` window is still identifiable.
        let trimmedName = displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolvedDisplayName = trimmedName.isEmpty ? vmDir.lastPathComponent : trimmedName

        return VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpBooter, in: vmDir) : nil,
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpSEPBooter, in: vmDir) : nil,
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
            variant: variant.virtualMachineVariant,
            softwareKeyboard: softwareKeyboard,
            noVphoned: self.noVphoned,
            displayName: resolvedDisplayName
        )
    }

    mutating func run() throws {}
}

struct VPhoneUSBMuxForwardSpec: ExpressibleByArgument, CustomStringConvertible, Sendable {
    let localPort: Int
    let guestPort: Int

    init?(argument: String) {
        let normalized = argument.replacingOccurrences(of: "=", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = Int(parts[0]),
              let guest = Int(parts[1]),
              (1 ... 65535).contains(local),
              (1 ... 65535).contains(guest)
        else {
            return nil
        }
        localPort = local
        guestPort = guest
    }

    var description: String {
        "\(localPort):\(guestPort)"
    }
}

struct PatchFirmwareCLI: ParsableCommand {
    enum VariantOption: String, CaseIterable, ExpressibleByArgument {
        case less
        case regular
        case dev
        case jb
        case exp

        var pipelineVariant: FirmwarePipeline.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }

        var virtualMachineVariant: VPhoneVirtualMachine.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-firmware",
        abstract: "Patch boot-chain firmware in a VM directory using the Swift pipeline"
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the VM directory that contains the *Restore* folder.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to patch.")
    var variant: VariantOption = .regular

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON."
    )
    var recordsOut: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-component progress output.")
    var quiet: Bool = false
    
    @Flag(name: .customLong("no-binpack"), help: "Exclude the SSH, VNC, ... binaries from being installed (patchless-only).")
    var noBinpack: Bool = false

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned from being installed (patchless-only).")
    var noVphoned: Bool = false

    @Flag(
        name: .customLong("force-exc-guard"),
        help: "Force-enable the EXC_GUARD (Mach port guard) disable patch on regular/jb/exp, even on bases where it isn't required to boot. Use if a third-party app's crash-reporting/RASP SDK trips a fatal GUARD_TYPE_MACH_PORT violation on launch. Always on for iOS 18 bases regardless of this flag."
    )
    var forceExcGuard: Bool = false

    @Flag(
        name: .customLong("frida"),
        help: "Opt in to Frida Stalker kernel relaxations (existing-thread follow + repeated VM_PROT_COPY). jb/exp only."
    )
    var frida: Bool = false

    mutating func run() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: vmDirectory,
            variant: variant.pipelineVariant,
            verbose: !quiet,
            noBinpack: noBinpack,
            noVphoned: noVphoned,
            forceExcGuard: forceExcGuard,
            enableFrida: frida
        )
        let records = try pipeline.patchAll()

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            print("[patch-firmware] wrote \(records.count) patch records to \(url.path)")
        } else {
            print("[patch-firmware] applied \(records.count) patches for \(variant.rawValue)")
        }
    }
}

struct PatchComponentCLI: ParsableCommand {
    enum ComponentOption: String, CaseIterable, ExpressibleByArgument {
        case txm
        case kernelBase = "kernel-base"
        // TESTING/DIAGNOSTICS ONLY — not part of any production flow.
        // Production JB patching runs through `patch-firmware --variant jb`; this
        // standalone option exists so `tests/test_jb_kernel_patches.sh` can run the
        // JB kernel layer over a single kernelcache and dump records via --records-out.
        // (txm / kernel-base, by contrast, are standalone single-component patchers.)
        case kernelJB = "kernel-jb"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes"
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:)
    )
    var input: URL

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON (for fast-loop validation)."
    )
    var recordsOut: String?

    @Option(
        name: .customLong("target-os"),
        help: "kernel-jb only: base iOS version the kernel will run under (e.g. 27.0). Gates the iOS-27-only JB patches exactly as the pipeline does. Omit to apply the full set (dev/test default)."
    )
    var targetOS: String?

    @Flag(
        name: .customLong("frida"),
        help: "kernel-jb only: opt in to the Frida Stalker kernel relaxations."
    )
    var frida: Bool = false

    mutating func run() throws {
        let payload = try IM4PHandler.load(contentsOf: input).payload
        let count: Int
        let patchedData: Data
        var records: [PatchRecord] = []

        switch component {
        case .txm:
            let patcher = TXMPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.patchedData

        case .kernelBase:
            let patcher = KernelPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.buffer.data
            records = patcher.patches

        case .kernelJB:
            // Mirrors the pipeline's jb kernel layer. In FirmwarePipeline each kernel
            // patcher runs on the *original* payload independently, so running
            // KernelJBPatcher standalone faithfully reproduces JB hook behavior
            // without the base patcher or the rest of the boot chain.
            let patcher = KernelJBPatcher(data: payload, verbose: !quiet)
            // Mirror the pipeline's per-base gating: apply the iOS-27-only patches when
            // --target-os is 27.x, skip them for an explicit non-27 target. With no
            // --target-os, default to applying them so the dev/test tool exercises the
            // full set.
            patcher.applyIOS27 = targetOS.map { $0.hasPrefix("27.") } ?? true
            patcher.applyFrida = frida
            count = try patcher.apply()
            patchedData = patcher.buffer.data
            records = patcher.patches
        }

        let outputDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try patchedData.write(to: output)

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            if !quiet {
                print("[patch-component] wrote \(records.count) patch records to \(url.path)")
            }
        }

        if !quiet {
            print("[patch-component] applied \(count) patches for \(component.rawValue)")
            print("[patch-component] wrote patched payload to \(output.path)")
        }
    }
}
