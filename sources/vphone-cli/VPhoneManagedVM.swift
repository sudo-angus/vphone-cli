import Foundation
import Observation

// MARK: - Run state / health

/// Lifecycle of a managed VM as the supervisor sees it.
enum VPhoneRunState: String, Sendable {
    case stopped // not running, clean
    case starting // child launched, guest not yet connected
    case running // child up, guest control channel connected
    case unresponsive // child up but heartbeat probe is failing
    case stopping // SIGINT sent, awaiting exit
    case failed // child exited non-zero

    var isActive: Bool {
        switch self {
        case .starting, .running, .unresponsive, .stopping: true
        case .stopped, .failed: false
        }
    }
}

/// Result of the heartbeat probe against a VM's `vphone.sock`.
enum VPhoneHealth: String, Sendable {
    case unknown // not running / not yet probed
    case starting // socket not up yet
    case healthy // host app responds, guest vsock connected
    case guestDisconnected // host app responds, guest vsock down (daemon/chain wedged)
    case unresponsive // host app did not answer the probe in time
}

/// Live state of a running VM's host-side networking plumbing — the part the
/// user previously had to reason about by reading `boot.sh` output and `pfctl`.
struct VPhoneNetworkStatus: Sendable {
    /// TCP-proxy workaround: the `vm_tproxy.py` relay is alive (pf anchor up).
    var tcpWorkaroundActive = false
    /// SOCKS5 bridge listening on its port; nil when SOCKS5 isn't configured.
    var socks5Listening: Bool?
    /// usbmux SSH forward (local → guest 22222) accepting connections.
    var sshListening = false
    /// usbmux RPC forward (local → guest 5910) accepting connections.
    var rpcListening = false
    var checkedAt: Date?
}

// MARK: - Log buffer

/// Append-only, capped, line-oriented log buffer for one VM's merged
/// stdout+stderr (host `[vphone]` logs interleaved with the guest serial
/// console). Observed by the live log panes; the durable copy is the rolling
/// file the supervisor writes in parallel.
///
/// Lines are classified once, at commit time, into two display channels —
/// host-networking plumbing vs everything else — so the Console pane stays
/// readable when the SOCKS5/tproxy relays get chatty, and so the panes can
/// consume new lines incrementally (via the monotonic totals) instead of
/// re-diffing the whole buffer on every chunk.
@Observable
@MainActor
final class VPhoneLogBuffer {
    enum Channel: Sendable {
        case console
        case network
    }

    /// Merged arrival-order lines, kept for whole-log export (`joined`).
    private(set) var lines: [String] = []
    private(set) var consoleLines: [String] = []
    private(set) var networkLines: [String] = []
    /// Lines ever committed per channel — never decreases when the capped
    /// arrays drop old lines, so incremental consumers can track their offset.
    private(set) var consoleTotal = 0
    private(set) var networkTotal = 0
    /// Not-yet-terminated tail of the stream (rendered live in Console).
    private(set) var partial = ""
    /// Set when a chunk ended on a bare `\r`, so a following `\n` is recognised
    /// as a CRLF (one newline) instead of an overwrite + spurious blank line.
    private var pendingCR = false
    /// Bump on every mutation so the view can cheaply detect "new output".
    private(set) var revision = 0
    /// Bumped on clear() so incremental consumers rebuild instead of appending.
    private(set) var generation = 0

    private let cap = 4000

    private static let networkTags = ["[tproxy]", "[socks5]", "[socks5-udp]", "[usbmux]", "[usbmuxd]"]

    static func isNetworkLine(_ line: String) -> Bool {
        networkTags.contains { line.contains($0) }
    }

    func appendChunk(_ text: String) {
        // Drop ANSI colour/cursor escapes (`make`, aria2c, brew emit them) and
        // process the bytes like a terminal: `\n` commits a line, a bare `\r`
        // returns to column 0 so progress bars overwrite in place instead of
        // stacking one line per refresh.
        for scalar in VPhoneANSI.strip(text).unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { commitLine(); continue }
                partial = "" // bare CR — overwrite the current line
            }
            switch scalar {
            case "\n": commitLine()
            case "\r": pendingCR = true
            default: partial.unicodeScalars.append(scalar)
            }
        }
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        if consoleLines.count > cap { consoleLines.removeFirst(consoleLines.count - cap) }
        if networkLines.count > cap { networkLines.removeFirst(networkLines.count - cap) }
        revision &+= 1
    }

    private func commitLine() {
        let line = partial
        partial = ""
        lines.append(line)
        if Self.isNetworkLine(line) {
            networkLines.append(line)
            networkTotal += 1
        } else {
            consoleLines.append(line)
            consoleTotal += 1
        }
    }

    func committedLines(in channel: Channel) -> [String] {
        switch channel {
        case .console: consoleLines
        case .network: networkLines
        }
    }

    func total(in channel: Channel) -> Int {
        switch channel {
        case .console: consoleTotal
        case .network: networkTotal
        }
    }

    /// All committed lines plus any not-yet-terminated tail, for display.
    var displayLines: [String] {
        partial.isEmpty ? lines : lines + [partial]
    }

    var joined: String {
        displayLines.joined(separator: "\n")
    }

    func clear() {
        lines = []
        consoleLines = []
        networkLines = []
        consoleTotal = 0
        networkTotal = 0
        partial = ""
        generation &+= 1
        revision &+= 1
    }
}

// MARK: - Managed VM

/// One VM in the manager's library: static config (from `config.plist` +
/// `vphone-meta.json`) plus live runtime/health/log state. Identity is the
/// canonical VM-directory path, which is stable across restarts.
@Observable
@MainActor
final class VPhoneManagedVM: Identifiable, Hashable {
    nonisolated let id: String
    nonisolated let dirURL: URL
    nonisolated let configURL: URL

    // Static-ish (refreshed from disk)
    var displayName: String
    var variant: String
    var iosVersion: String?
    var cpuCount: Int
    var memoryBytes: UInt64
    /// `machineIdentifier` present in config.plist ⇒ the VM has booted at least
    /// once and has a stable ECID/identity.
    var provisioned: Bool
    /// Allocated on-disk size; nil while being computed off-main.
    var sizeBytes: Int64?
    /// Extra raw boot flags (escape hatch) appended after the structured options.
    var bootFlags: [String]
    /// Whether to request the host TCP-proxy workaround for this VM.
    var enableTCPWorkaround: Bool
    /// Use the iOS software keyboard (drop the USB keyboard).
    var softwareKeyboard: Bool
    /// Expose the guest network as SOCKS5 on 127.0.0.1:<port>; 0 = off.
    var socks5Port: Int
    /// Fixed local SSH-forward port, or nil to auto-assign a free one.
    var sshForwardPref: Int?
    /// Fixed local RPC-forward port, or nil to auto-assign a free one.
    var rpcForwardPref: Int?

    // Runtime
    var runState: VPhoneRunState = .stopped
    var pid: Int32?
    /// Running but not spawned by this manager instance (e.g. an older
    /// `make boot`, or the manager was relaunched while it ran).
    var adopted = false
    var startedAt: Date?
    var lastExitCode: Int32?
    var lastMessage: String?

    // Effective forwarded host ports while running (display only)
    var sshPort: Int?
    var rpcPort: Int?
    var usingTCPWorkaround = false

    // Health
    var health: VPhoneHealth = .unknown
    var healthCaps: [String] = []

    // Networking
    var network = VPhoneNetworkStatus()

    let log = VPhoneLogBuffer()

    init(
        dirURL: URL,
        displayName: String,
        variant: String,
        iosVersion: String?,
        cpuCount: Int,
        memoryBytes: UInt64,
        provisioned: Bool,
        bootFlags: [String],
        enableTCPWorkaround: Bool,
        softwareKeyboard: Bool,
        socks5Port: Int,
        sshForwardPref: Int?,
        rpcForwardPref: Int?
    ) {
        self.dirURL = dirURL.standardizedFileURL
        id = dirURL.standardizedFileURL.path
        configURL = dirURL.standardizedFileURL.appendingPathComponent("config.plist")
        self.displayName = displayName
        self.variant = variant
        self.iosVersion = iosVersion
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.provisioned = provisioned
        self.bootFlags = bootFlags
        self.enableTCPWorkaround = enableTCPWorkaround
        self.softwareKeyboard = softwareKeyboard
        self.socks5Port = socks5Port
        self.sshForwardPref = sshForwardPref
        self.rpcForwardPref = rpcForwardPref
    }

    nonisolated static func == (lhs: VPhoneManagedVM, rhs: VPhoneManagedVM) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: Derived

    var memoryMB: Int { Int(memoryBytes / 1024 / 1024) }

    var displaySize: String {
        guard let sizeBytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var hardwareSummary: String {
        "\(cpuCount) CPU · \(memoryMB) MB"
    }

    /// The Unix control socket a running child publishes next to the config.
    var controlSocketURL: URL {
        dirURL.appendingPathComponent("vphone.sock")
    }
}
