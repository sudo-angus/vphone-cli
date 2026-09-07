import Foundation
import VPhoneCore

/// Discovers and describes the VM directories the manager presents as a
/// library. A VM is any directory containing a `config.plist`. Two roots are
/// scanned: the legacy single-slot `vm/` (so an existing install shows up
/// immediately) and a `vms/` library root where future VMs live, each in its
/// own directory. The on-disk VM dir is already self-contained and relocatable
/// (relative paths in the manifest), so directory == VM with no extra wiring.
@MainActor
final class VPhoneVMRegistry {
    let repoRoot: URL
    let libraryRoot: URL
    let legacyVMDir: URL

    init(repoRoot: URL, libraryRoot: URL? = nil) {
        self.repoRoot = repoRoot
        self.libraryRoot = libraryRoot ?? repoRoot.appendingPathComponent("vms")
        legacyVMDir = repoRoot.appendingPathComponent("vm")
    }

    // MARK: Discovery

    /// All VM directories, de-duplicated and ordered (legacy `vm/` first, then
    /// `vms/*` alphabetically).
    func discover() -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func consider(_ dir: URL) {
            let std = dir.standardizedFileURL
            guard !seen.contains(std.path) else { return }
            guard hasConfig(std) else { return }
            seen.insert(std.path)
            result.append(std)
        }

        consider(legacyVMDir)

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                consider(entry)
            }
        }

        return result
    }

    private func hasConfig(_ dir: URL) -> Bool {
        var isDir: ObjCBool = false
        let cfg = dir.appendingPathComponent("config.plist").path
        return FileManager.default.fileExists(atPath: cfg, isDirectory: &isDir) && !isDir.boolValue
    }

    /// How many existing VMs were restored from each firmware build, read from
    /// the `iPhone<device>_<version>_<build>_Restore` folder the pipeline leaves
    /// in each VM dir. Lets the create wizard default to a firmware the user
    /// already has a device on — no re-download, and proven on this machine.
    func installedBuildCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for dir in discover() {
            var builds = Set<String>()
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in entries where name.hasPrefix("iPhone") && name.hasSuffix("_Restore") {
                // "iPhone17,3_26.1_23B85_Restore" → build is the last `_`-field
                let core = name.dropFirst("iPhone".count).dropLast("_Restore".count)
                if let us = core.lastIndex(of: "_") {
                    builds.insert(String(core[core.index(after: us)...]))
                }
            }
            for b in builds { counts[b, default: 0] += 1 }
        }
        return counts
    }

    // MARK: Loading

    /// Build a managed VM for a directory by merging the boot manifest with the
    /// manager sidecar. Returns nil if the manifest can't be decoded.
    func load(dir: URL) -> VPhoneManagedVM? {
        let std = dir.standardizedFileURL
        let configURL = std.appendingPathComponent("config.plist")
        guard let manifest = try? VPhoneVirtualMachineManifest.load(from: configURL) else {
            return nil
        }
        let meta = VPhoneVMMeta.load(fromVMDir: std)

        return VPhoneManagedVM(
            dirURL: std,
            displayName: meta?.displayName ?? defaultDisplayName(for: std),
            variant: meta?.variant ?? "regular",
            iosVersion: meta?.iosVersion,
            cpuCount: Int(manifest.cpuCount),
            memoryBytes: manifest.memorySize,
            provisioned: !manifest.machineIdentifier.isEmpty,
            bootFlags: meta?.bootFlags ?? [],
            enableTCPWorkaround: meta?.enableTCPWorkaround ?? true,
            softwareKeyboard: meta?.softwareKeyboard ?? true,
            socks5Port: meta?.socks5Port ?? 0,
            sshForwardPref: meta?.sshForwardPort,
            rpcForwardPref: meta?.rpcForwardPort
        )
    }

    /// Persist the editable options of a VM back into its `vphone-meta.json`,
    /// preserving fields the manager doesn't edit (createdAt, notes).
    func saveMeta(for vm: VPhoneManagedVM) throws {
        var meta = VPhoneVMMeta.load(fromVMDir: vm.dirURL) ?? VPhoneVMMeta()
        meta.displayName = vm.displayName
        meta.variant = vm.variant
        meta.iosVersion = vm.iosVersion
        meta.enableTCPWorkaround = vm.enableTCPWorkaround
        meta.softwareKeyboard = vm.softwareKeyboard
        meta.socks5Port = vm.socks5Port == 0 ? nil : vm.socks5Port
        meta.sshForwardPort = vm.sshForwardPref
        meta.rpcForwardPort = vm.rpcForwardPref
        meta.bootFlags = vm.bootFlags.isEmpty ? nil : vm.bootFlags
        try meta.write(toVMDir: vm.dirURL)
    }

    private func defaultDisplayName(for dir: URL) -> String {
        let name = dir.lastPathComponent
        return name == "vm" ? "Default VM" : name
    }

    // MARK: Size

    /// Allocated on-disk size (`du -s -k`). Sparse images make apparent size
    /// meaningless, so we report blocks actually allocated. Runs off the main
    /// actor; can take a moment on a VM with a full firmware tree.
    nonisolated static func allocatedSize(of dir: URL) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-s", "-k", dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let field = text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kb = Int64(field)
        else { return nil }
        return kb * 1024
    }

    // MARK: Repo root

    /// Locate the repo root by walking up from the executable and the current
    /// directory until we find the marker files the boot/elevation flow needs.
    static func findRepoRoot() -> URL {
        let marker = "scripts/start_amfidont_for_vphone.sh"
        let makefile = "Makefile"

        func isRepo(_ dir: URL) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path)
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent(makefile).path)
        }

        // An installed /Applications/VPhone.app is a *copy* of the build (a real
        // bundle so Spotlight/Launchpad index it — they skip symlinked apps), so
        // it can't find the repo by walking up the filesystem. `make install_app`
        // records the source clone in this resource; trust it while it still looks
        // like the repo.
        if let pathURL = Bundle.main.url(forResource: "repo-root", withExtension: nil),
           let raw = try? String(contentsOf: pathURL, encoding: .utf8) {
            let dir = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if isRepo(dir) { return dir }
        }

        var roots: [URL] = []
        roots.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
        )
        if let exe = Bundle.main.executableURL {
            roots.append(exe.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        for root in roots {
            var dir = root
            for _ in 0 ..< 10 {
                if isRepo(dir) { return dir }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Locate the *entitled* boot binary the supervisor should spawn. The
    /// manager itself is signed WITHOUT the private virtualization entitlements
    /// so it can always launch and bootstrap amfidont; the children it spawns
    /// are the entitled binary, which AMFI only admits once amfidont is up.
    static func locateBootBinary(repoRoot: URL) -> URL {
        let candidates = [
            repoRoot.appendingPathComponent(".build/vphone-cli.app/Contents/MacOS/vphone-cli"),
            repoRoot.appendingPathComponent(".build/release/vphone-cli"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            return c
        }
        return Bundle.main.executableURL ?? candidates[0]
    }
}
