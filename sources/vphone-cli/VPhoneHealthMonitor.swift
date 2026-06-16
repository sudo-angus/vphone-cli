import Foundation

/// Periodic liveness probe for running VMs.
///
/// The boot binary exposes no heartbeat, and `isConnected` only proves a vsock
/// handshake — not that the host app's run loop is still servicing requests.
/// The manager closes that gap by talking to each VM's `vphone.sock`: a
/// `{"t":"health"}` line is answered by the host app's accept loop with
/// `{ok, connected, caps}`. Three outcomes matter:
///   • a reply with `connected:true`  → healthy (green)
///   • a reply with `connected:false` → guest vsock dropped (amber)
///   • no reply within the timeout    → host app wedged (red → restart prompt)
/// This catches the user's "Host disconnected / forwarding died" cases. A
/// SpringBoard that is wedged while the daemon still answers is a deeper tier
/// (screenshot diffing) deliberately left for later.
@MainActor
final class VPhoneHealthMonitor {
    /// Host-side network plumbing state, carried in the `health` reply so we
    /// never probe ports (a probe `connect()` opened a real guest connection on
    /// every tick and spammed the network log). Optionals are nil when the field
    /// is absent — e.g. an adopted VM whose binary predates this reply.
    private struct HealthNet: Sendable {
        var sshListening: Bool?
        var rpcListening: Bool?
        var socks5Listening: Bool?
        var socks5Endpoint: String?
        var guestIP: String?
    }

    private enum Probe: Sendable {
        case notUp
        case responded(connected: Bool, caps: [String], stall: Int, net: HealthNet)
        case timeout
    }

    /// Cycles of consecutive non-response before a VM is declared unresponsive.
    private let unresponsiveThreshold = 3
    /// Cycles (×3 s) the guest vsock may stay down before we treat it as the
    /// VZ-helper wedge rather than a still-booting guest. Generous enough to
    /// clear the slowest first boot we've seen (~80 s to vphoned). This is the
    /// *slow* fallback; a wedge that fingerprints itself (see below) recovers in
    /// a fraction of this.
    private let guestDownThreshold = 40
    /// When the host app reports a vsock *stall* streak this high — connect
    /// callbacks dropped or handshakes stalled, the documented VZ-helper wedge —
    /// recover immediately instead of waiting out `guestDownThreshold`. A
    /// still-booting guest fails connect promptly (ECONNRESET) and never raises
    /// this, so the fast path can't fire on a merely-slow boot. ~2 stalls ≈ 20 s.
    private let wedgeStallThreshold = 2

    private var timer: Timer?
    private var streak: [String: Int] = [:]
    private var guestDownStreak: [String: Int] = [:]
    private var prompted: Set<String> = []
    /// VMs for which the fast wedge path has already fired this episode; cleared
    /// on a clean reconnect or an explicit reset so it re-arms after each heal.
    private var wedgeFired: Set<String> = []

    /// Supplies the current VM list; set by the model.
    var vmsProvider: (() -> [VPhoneManagedVM])?
    /// Fired once per wedge episode so the UI can offer a restart.
    var onUnresponsive: ((VPhoneManagedVM) -> Void)?
    /// Fired (repeatedly, ~every `guestDownThreshold` cycles) when the host app
    /// is alive but the guest control channel has been down long past a normal
    /// boot — the documented VZ vsock-helper wedge. The model decides whether to
    /// auto-restart into a fresh helper or surface a manual prompt.
    var onWedgeSuspected: ((VPhoneManagedVM) -> Void)?

    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private struct TickResult: Sendable {
        let id: String
        let health: Probe
        let tproxyActive: Bool
    }

    private func tick() async {
        guard let vms = vmsProvider?() else { return }
        let active = vms.filter { $0.runState.isActive }
        guard !active.isEmpty else { return }

        // Probe heartbeat for all VMs concurrently off the main actor. Listener
        // state rides the health reply; only the tproxy relay still needs its own
        // check (a pgrep, which produces no network-log noise).
        let results: [TickResult] = await withTaskGroup(of: TickResult.self) { group in
            for vm in active {
                let id = vm.id
                let path = vm.controlSocketURL.path
                let usingTCP = vm.usingTCPWorkaround
                group.addTask {
                    TickResult(
                        id: id,
                        health: Self.probe(socketPath: path),
                        tproxyActive: usingTCP && VPhoneSupervisor.tproxyRelayRunning()
                    )
                }
            }
            var acc: [TickResult] = []
            for await r in group { acc.append(r) }
            return acc
        }

        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        for r in results {
            guard let vm = byID[r.id] else { continue }
            apply(r.health, to: vm)
            guard vm.runState.isActive else { continue }

            var s = VPhoneNetworkStatus()
            s.checkedAt = Date()
            s.tcpWorkaroundActive = r.tproxyActive
            if case let .responded(_, _, _, net) = r.health {
                s.sshListening = net.sshListening ?? false
                s.rpcListening = net.rpcListening ?? false
                s.socks5Listening = net.socks5Listening
                s.socks5Endpoint = net.socks5Endpoint
                s.guestIP = net.guestIP
            }
            vm.network = s
        }
    }

    private func apply(_ probe: Probe, to vm: VPhoneManagedVM) {
        guard vm.runState.isActive else { return }

        switch probe {
        case let .responded(connected, caps, stall, _):
            if connected {
                streak[vm.id] = 0
                guestDownStreak[vm.id] = 0
                wedgeFired.remove(vm.id)
                prompted.remove(vm.id)
                vm.healthCaps = caps
                vm.health = .healthy
                if vm.runState == .starting || vm.runState == .unresponsive {
                    vm.runState = .running
                }
            } else {
                // Host app is alive, guest vsock is down.
                streak[vm.id] = 0
                vm.health = .guestDisconnected
                if vm.runState == .unresponsive { vm.runState = .running }

                if stall >= wedgeStallThreshold {
                    // The host app fingerprints this as the VZ-helper wedge
                    // (connect callbacks dropped / handshakes stalled), not a
                    // booting guest. Recover now — a fresh helper (full child
                    // restart) is the only thing that clears it. Fire once per
                    // episode; re-arms after the heal resets our state.
                    if wedgeFired.insert(vm.id).inserted {
                        guestDownStreak[vm.id] = 0
                        onWedgeSuspected?(vm)
                    }
                } else {
                    // Slow fallback: vsock down without the wedge fingerprint
                    // (booting guest, guest crash, or the connect-succeeds /
                    // handshake-times-out surface). Give a normal boot plenty of
                    // room before treating it as a wedge.
                    let down = (guestDownStreak[vm.id] ?? 0) + 1
                    if down >= guestDownThreshold {
                        guestDownStreak[vm.id] = 0 // rearm for the next window
                        onWedgeSuspected?(vm)
                    } else {
                        guestDownStreak[vm.id] = down
                    }
                }
            }

        case .notUp:
            // During the boot grace window the socket simply isn't up yet.
            if vm.runState == .starting { return }
            bumpUnresponsive(vm)

        case .timeout:
            bumpUnresponsive(vm)
        }
    }

    private func bumpUnresponsive(_ vm: VPhoneManagedVM) {
        let next = (streak[vm.id] ?? 0) + 1
        streak[vm.id] = next
        guard next >= unresponsiveThreshold else { return }
        vm.health = .unresponsive
        vm.runState = .unresponsive
        if !prompted.contains(vm.id) {
            prompted.insert(vm.id)
            onUnresponsive?(vm)
        }
    }

    func reset(_ vm: VPhoneManagedVM) {
        streak[vm.id] = 0
        guestDownStreak[vm.id] = 0
        wedgeFired.remove(vm.id)
        prompted.remove(vm.id)
    }

    // MARK: - Probe

    private nonisolated static func probe(socketPath: String) -> Probe {
        guard FileManager.default.fileExists(atPath: socketPath) else { return .notUp }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notUp }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return .notUp }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .notUp }

        // Bound the read so a wedged host-app main actor surfaces as a timeout.
        var tv = timeval(tv_sec: 2, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request = "{\"t\":\"health\",\"screen\":false}\n"
        let sent: Int = request.withCString { ptr in write(fd, ptr, strlen(ptr)) }
        guard sent > 0 else { return .timeout }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while response.count < 64 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                response.append(contentsOf: buf[..<n])
                if response.contains(0x0A) { break }
            } else {
                break // EOF or timeout (errno EAGAIN)
            }
        }
        guard !response.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else { return .timeout }

        // Any well-formed reply proves the host app's run loop is alive — that
        // is the whole point of the probe. A binary predating the `health` verb
        // answers `{"ok":false,"error":"unknown command: health"}`; that is
        // "alive but old", not wedged, so default connected = true when the
        // field is absent. A current binary reports the real vsock state.
        let connectedFlag = json["connected"] as? Bool ?? true
        let caps = json["caps"] as? [String] ?? []
        // Absent on binaries predating the wedge-stall signal — treat as 0
        // (no fingerprint), so they fall back to the slow guest-down path.
        let stall = json["vsock_stall"] as? Int ?? 0
        var net = HealthNet()
        net.sshListening = json["ssh_listening"] as? Bool
        net.rpcListening = json["rpc_listening"] as? Bool
        net.socks5Listening = json["socks5_listening"] as? Bool
        net.socks5Endpoint = json["socks5_endpoint"] as? String
        net.guestIP = json["guest_ip"] as? String
        return .responded(connected: connectedFlag, caps: caps, stall: stall, net: net)
    }
}
