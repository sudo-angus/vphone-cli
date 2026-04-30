import Darwin
import Foundation
import Virtualization

/// Host-side TCP listener that bridges incoming SOCKS5 sessions over vsock
/// to the guest's `vphoned_socks5` listener.
///
/// The host side speaks no SOCKS5 — it is a transparent byte pump. SOCKS5
/// handshake / CONNECT / DNS resolution happen entirely inside the iOS guest
/// (`vphoned_socks5.m`), so traffic dispatched by guest `connect()` follows
/// the iOS routing table — including any utun installed by an active VPN
/// PacketTunnelProvider. That is the whole point: the host borrows the
/// guest's network access without re-implementing the VPN.
@MainActor
final class VPhoneSocks5Bridge {
    private let listenHost: String
    private let listenPort: UInt16
    private let guestPort: UInt32
    private weak var device: VZVirtioSocketDevice?
    private var listenFd: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var stopped = false

    init(listenHost: String = "127.0.0.1", listenPort: UInt16, guestPort: UInt32 = 1340) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.guestPort = guestPort
    }

    func start(device: VZVirtioSocketDevice) {
        self.device = device

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[socks5] socket() failed: \(errnoString())")
            return
        }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(listenHost)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("[socks5] bind \(listenHost):\(listenPort) failed: \(errnoString())")
            Darwin.close(fd)
            return
        }
        guard Darwin.listen(fd, 32) == 0 else {
            print("[socks5] listen failed: \(errnoString())")
            Darwin.close(fd)
            return
        }

        listenFd = fd
        let queue = DispatchQueue(label: "vphone.socks5.accept", qos: .utility)
        acceptQueue = queue

        print("[socks5] bridge listening on \(listenHost):\(listenPort) → guest vsock port \(guestPort)")

        queue.async { [weak self] in
            self?.runAcceptLoop(fd: fd)
        }
    }

    func stop() {
        stopped = true
        if listenFd >= 0 {
            Darwin.shutdown(listenFd, SHUT_RDWR)
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    // MARK: - Accept loop

    nonisolated private func runAcceptLoop(fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // bridge stopped or fatal — exit loop
                return
            }
            // TCP_NODELAY: SOCKS5 is a fairly chatty handshake; small messages
            // benefit from disabling Nagle on the client leg.
            var one: Int32 = 1
            _ = Darwin.setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            Task { @MainActor [weak self] in
                self?.openVsockAndBridge(clientFd: client)
            }
        }
    }

    // MARK: - Per-connection

    private func openVsockAndBridge(clientFd: Int32) {
        guard let device else {
            Darwin.close(clientFd)
            return
        }
        device.connect(toPort: guestPort) { result in
            switch result {
            case let .success(conn):
                let vsockFd = conn.fileDescriptor
                Self.spliceBoth(a: clientFd, b: vsockFd) {
                    // VZVirtioSocketConnection retains until cleanup; closing
                    // the fd is sufficient for our half. Capture conn so it
                    // outlives the splice (otherwise ARC may close the fd
                    // mid-pump).
                    _ = conn
                }
            case let .failure(err):
                print("[socks5] vsock connect failed: \(err)")
                Darwin.close(clientFd)
            }
        }
    }

    // MARK: - Byte splice

    /// Pumps bytes between two fds full-duplex until both directions close.
    /// On completion calls `onDone` so the caller can release any retained
    /// connection wrapper.
    nonisolated private static func spliceBoth(a: Int32, b: Int32, onDone: @escaping () -> Void) {
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .utility)

        group.enter()
        q.async {
            pump(from: a, to: b)
            // Half-close the write side of the peer so the other direction
            // can drain its remaining bytes and then unblock its read().
            _ = Darwin.shutdown(b, SHUT_WR)
            group.leave()
        }

        group.enter()
        q.async {
            pump(from: b, to: a)
            _ = Darwin.shutdown(a, SHUT_WR)
            group.leave()
        }

        group.notify(queue: q) {
            Darwin.close(a)
            Darwin.close(b)
            onDone()
        }
    }

    nonisolated private static func pump(from src: Int32, to dst: Int32) {
        let bufSize = 16 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = Darwin.read(src, buf, bufSize)
            if n <= 0 { return }
            var off = 0
            while off < n {
                let w = Darwin.write(dst, buf + off, n - off)
                if w <= 0 { return }
                off += w
            }
        }
    }

    // MARK: - errno helper

    nonisolated private func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
