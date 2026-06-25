import AppKit
import Foundation
import Observation

enum VPhoneManagerError: LocalizedError {
    case logOpenFailed(String)
    case exportFailed(Int)
    case amfidontMissing
    case sudoersInvalid(String)
    case authorizationCancelled
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .logOpenFailed(path): "Could not open log file at \(path)"
        case let .exportFailed(code): "Log export failed (ditto exit \(code))"
        case .amfidontMissing:
            "amfidont is not installed for any python3 on this host. Install it with: xcrun python3 -m pip install -U amfidont"
        case let .sudoersInvalid(detail): "Generated sudoers rule failed validation: \(detail)"
        case .authorizationCancelled: "Authorization was cancelled."
        case let .authorizationFailed(detail): "Authorization failed: \(detail)"
        }
    }
}

/// Top-level state for the manager window. Owns the VM library and brokers
/// every action (start/stop/restart, authorize, export) across the registry,
/// supervisor, health monitor, and privilege helper.
@Observable
@MainActor
final class VPhoneManagerModel {
    let registry: VPhoneVMRegistry
    let supervisor: VPhoneSupervisor
    let health: VPhoneHealthMonitor
    let privilege: VPhonePrivilege

    var vms: [VPhoneManagedVM] = []
    var selection: VPhoneManagedVM.ID?

    var authStatus: VPhonePrivilege.AuthStatus = .notAuthorized
    var amfidontRunning = false
    var amfidontDetail: String?

    var error: String?
    /// A non-modal prompt (guest unresponsive, or a wedge auto-recovery gave up).
    var restartPrompt: RestartPrompt?
    var busy = false

    /// How many times a wedged guest is auto-restarted into a fresh helper
    /// before we stop and ask the user (a fresh helper that re-wedges usually
    /// means the host itself needs a restart).
    private let maxAutoHeals = 2
    private var wedgeHealAttempts: [VPhoneManagedVM.ID: Int] = [:]
    private var wedgePrompted: Set<VPhoneManagedVM.ID> = []

    struct RestartPrompt: Identifiable {
        let id = UUID()
        let vmID: VPhoneManagedVM.ID
        let name: String
        var title: String
        var message: String
    }

    init(registry: VPhoneVMRegistry, privilege: VPhonePrivilege, executableURL: URL) {
        self.registry = registry
        self.privilege = privilege
        supervisor = VPhoneSupervisor(executableURL: executableURL, repoRoot: registry.repoRoot)
        health = VPhoneHealthMonitor()

        supervisor.vmFinder = { [weak self] id in self?.vms.first { $0.id == id } }
        health.vmsProvider = { [weak self] in self?.vms ?? [] }
        health.onUnresponsive = { [weak self] vm in
            self?.restartPrompt = RestartPrompt(
                vmID: vm.id, name: vm.displayName,
                title: "“\(vm.displayName)” stopped responding",
                message: "The guest is no longer answering the manager. Restart it?"
            )
        }
        health.onWedgeSuspected = { [weak self] vm in
            Task { @MainActor in await self?.autoHealWedge(vm) }
        }
    }

    var selectedVM: VPhoneManagedVM? {
        guard let selection else { return nil }
        return vms.first { $0.id == selection }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        refreshLibrary()
        supervisor.reconcileAdoptions(vms)
        if selection == nil { selection = vms.first?.id }
        computeSizes()
        // Start the heartbeat before the amfidont check: that check shells out to
        // sudo/python and has wedged here before, and the VM lifecycle UI (the
        // "Starting" → "Running" transition lives on this timer) must never be
        // held hostage to it.
        health.start()
        await refreshAuth()
    }

    func teardownForQuit() {
        supervisor.stopAllOwned()
        health.stop()
    }

    // MARK: - Library

    func refreshLibrary() {
        let dirs = registry.discover()
        let existing = Dictionary(uniqueKeysWithValues: vms.map { ($0.id, $0) })
        var next: [VPhoneManagedVM] = []
        for dir in dirs {
            let key = dir.standardizedFileURL.path
            if let live = existing[key] {
                next.append(live) // keep the live object (and its runtime state)
            } else if let vm = registry.load(dir: dir) {
                next.append(vm)
            }
        }
        vms = next
        supervisor.reconcileAdoptions(vms)
        computeSizes()
        if let selection, !vms.contains(where: { $0.id == selection }) {
            self.selection = vms.first?.id
        }
    }

    private func computeSizes() {
        for vm in vms {
            let dir = vm.dirURL
            Task.detached {
                let size = VPhoneVMRegistry.allocatedSize(of: dir)
                await MainActor.run { vm.sizeBytes = size }
            }
        }
    }

    // MARK: - Actions

    func start(_ vm: VPhoneManagedVM) async {
        guard !vm.runState.isActive else { return }
        resetHealState(vm)
        await launch(vm)
    }

    func stop(_ vm: VPhoneManagedVM) async {
        resetHealState(vm)
        await supervisor.stop(vm)
        health.reset(vm)
    }

    func restart(_ vm: VPhoneManagedVM) async {
        resetHealState(vm)
        await supervisor.stop(vm)
        health.reset(vm)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await launch(vm)
    }

    /// Ensure the AMFI bypass is up, then spawn the boot child. Shared by the
    /// user Start/Restart actions and the wedge auto-heal (which must *not*
    /// reset the heal counters, so they keep counting across its restarts).
    private func launch(_ vm: VPhoneManagedVM) async {
        let amfi = await privilege.ensureAmfidont()
        switch amfi {
        case .running, .started:
            amfidontRunning = true
        case .needsAuthorization:
            amfidontRunning = false
            authStatus = .notAuthorized
            error = "AMFI bypass needs admin authorization before VMs can launch. Click “Authorize admin”."
            return
        case .unavailable:
            error = VPhoneManagerError.amfidontMissing.localizedDescription
            return
        case let .failed(detail):
            error = "Could not start amfidont: \(detail)"
            return
        }

        do {
            try supervisor.start(vm)
            health.reset(vm)
        } catch {
            self.error = "Failed to start \(vm.displayName): \(error.localizedDescription)"
        }
    }

    private func resetHealState(_ vm: VPhoneManagedVM) {
        wedgeHealAttempts[vm.id] = 0
        wedgePrompted.remove(vm.id)
    }

    /// The guest control channel has been down well past a normal boot — the
    /// documented VZ vsock-helper wedge, where guest→host vsock is dropped for
    /// the whole VM lifetime and only a fresh helper recovers. Restart the child
    /// (new process → new helper) a bounded number of times, then fall back to a
    /// manual prompt since a fresh helper that still wedges means the host needs
    /// a restart. Bypasses `restart(_:)` so the heal counter survives.
    private func autoHealWedge(_ vm: VPhoneManagedVM) async {
        guard vm.runState.isActive else { return }
        let attempts = wedgeHealAttempts[vm.id] ?? 0
        guard attempts < maxAutoHeals else {
            if wedgePrompted.insert(vm.id).inserted {
                vm.log.appendChunk(
                    "[manager] auto-recovery exhausted after \(maxAutoHeals) restarts; the host Virtualization helper looks wedged (a Mac restart clears it).\n"
                )
                restartPrompt = RestartPrompt(
                    vmID: vm.id, name: vm.displayName,
                    title: "“\(vm.displayName)” can’t reach its guest",
                    message: "The guest control channel stayed down through \(maxAutoHeals) automatic restarts. The host Virtualization helper is likely wedged — restarting your Mac clears it. Try one more restart anyway?"
                )
            }
            return
        }

        wedgeHealAttempts[vm.id] = attempts + 1
        vm.log.appendChunk(
            "[manager] guest control channel down past the boot window — restarting into a fresh Virtualization helper to clear a suspected vsock wedge (attempt \(attempts + 1)/\(maxAutoHeals))\n"
        )
        await supervisor.stop(vm)
        health.reset(vm)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await launch(vm)
    }

    // MARK: - Privilege

    func refreshAuth() async {
        authStatus = privilege.authStatus()
        let result = await privilege.ensureAmfidont()
        switch result {
        case .running, .started:
            amfidontRunning = true
            amfidontDetail = nil
        case .needsAuthorization:
            amfidontRunning = false
            amfidontDetail = "Authorize to start the AMFI bypass automatically."
        case .unavailable:
            amfidontRunning = false
            amfidontDetail = "amfidont not installed (xcrun python3 -m pip install -U amfidont)."
        case let .failed(detail):
            amfidontRunning = false
            amfidontDetail = detail.isEmpty ? "amfidont failed to start." : detail
        }
    }

    func authorize() async {
        busy = true
        defer { busy = false }
        do {
            try await privilege.authorize()
            await refreshAuth()
        } catch let VPhoneManagerError.authorizationCancelled {
            _ = VPhoneManagerError.authorizationCancelled // user cancelled; no error banner
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deauthorize() async {
        busy = true
        defer { busy = false }
        do {
            try await privilege.deauthorize()
            await refreshAuth()
        } catch let VPhoneManagerError.authorizationCancelled {
            // cancelled — nothing to do
            _ = VPhoneManagerError.authorizationCancelled
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Logs

    func exportLogs(_ vm: VPhoneManagedVM) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.displayName.replacingOccurrences(of: " ", with: "-"))-logs.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await supervisor.exportLogs(vm, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Options

    func saveOptions(for vm: VPhoneManagedVM) {
        do {
            try registry.saveMeta(for: vm)
        } catch {
            self.error = "Could not save options for \(vm.displayName): \(error.localizedDescription)"
        }
    }

    /// Export what the Console pane shows (network channel excluded). The full
    /// merged history lives in the "Export Log Bundle" zip from the sidebar menu.
    func exportConsoleLog(_ vm: VPhoneManagedVM) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.displayName.replacingOccurrences(of: " ", with: "-"))-console.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = vm.log.consoleLines
        if !vm.log.partial.isEmpty { lines.append(vm.log.partial) }
        let body = lines.isEmpty ? "(no console output captured yet)" : lines.joined(separator: "\n")
        do {
            try body.data(using: .utf8)?.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Networking

    func exportNetworkLog(_ vm: VPhoneManagedVM) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.displayName.replacingOccurrences(of: " ", with: "-"))-network.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = vm.log.networkLines
        let header = "# Network log for \(vm.displayName)\n# tproxy=\(vm.network.tcpWorkaroundActive) "
            + "ssh=\(vm.sshPort.map(String.init) ?? "-") rpc=\(vm.rpcPort.map(String.init) ?? "-") "
            + "socks5=\(vm.socks5Port)\n\n"
        let body = lines.isEmpty ? "(no networking log lines captured yet)" : lines.joined(separator: "\n")
        do {
            try (header + body).data(using: .utf8)?.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Finder / removal

    func revealInFinder(_ vm: VPhoneManagedVM) {
        NSWorkspace.shared.activateFileViewerSelecting([vm.dirURL])
    }

    /// Move a (stopped) VM directory to the Trash and drop it from the library.
    func moveToTrash(_ vm: VPhoneManagedVM) {
        guard !vm.runState.isActive else {
            error = "Stop \(vm.displayName) before deleting it."
            return
        }
        do {
            try FileManager.default.trashItem(at: vm.dirURL, resultingItemURL: nil)
            vms.removeAll { $0.id == vm.id }
            if selection == vm.id { selection = vms.first?.id }
        } catch {
            self.error = "Could not move \(vm.displayName) to Trash: \(error.localizedDescription)"
        }
    }
}
