import Darwin
import Foundation
import Virtualization

/// Host-side SOCKS5 entry point.
///
/// Parses just enough of the SOCKS5 handshake to route by CMD:
///   - CONNECT (0x01)        → replays the handshake to the guest's TCP
///                              SOCKS5 listener (vsock 1340) and splices.
///   - UDP ASSOCIATE (0x03)  → terminates the SOCKS5 handshake on the host,
///                              allocates a UDP relay socket, and ships
///                              datagrams to/from the guest over a separate
///                              framed vsock stream (vsock 1341).
///
/// Why split: SOCKS5 UDP ASSOCIATE requires the server to advertise a
/// client-reachable UDP endpoint (BND.ADDR/BND.PORT). The guest can't expose
/// a UDP port to the host LAN — vsock is SOCK_STREAM only — so the host owns
/// the UDP relay socket. The guest still does the actual `sendto()`, picking
/// up any active iOS VPN utun via the iOS routing table; the host bridge
/// just frames each datagram with its target addr/port.
@MainActor
final class VPhoneSocks5Bridge {
    private let listenHost: String
    private let listenPort: UInt16
    private let guestTcpPort: UInt32
    private let guestUdpPort: UInt32
    private weak var device: VZVirtioSocketDevice?
    private var listenFd: Int32 = -1
    private var stopped = false

    init(
        listenHost: String = "127.0.0.1",
        listenPort: UInt16,
        guestTcpPort: UInt32 = 1340,
        guestUdpPort: UInt32 = 1341
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.guestTcpPort = guestTcpPort
        self.guestUdpPort = guestUdpPort
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
        print(
            "[socks5] bridge listening on \(listenHost):\(listenPort) → guest vsock tcp=\(guestTcpPort) udp=\(guestUdpPort)"
        )

        DispatchQueue(label: "vphone.socks5.accept", qos: .utility).async { [weak self] in
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
                return
            }
            // TCP_NODELAY: SOCKS5 handshake is small/chatty; disable Nagle.
            var one: Int32 = 1
            _ = Darwin.setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            Task { @MainActor [weak self] in
                self?.parseAndDispatch(clientFd: client)
            }
        }
    }

    // MARK: - SOCKS5 parsing

    private func parseAndDispatch(clientFd: Int32) {
        guard device != nil else {
            Darwin.close(clientFd)
            return
        }

        // Parse off the main actor — read/write blocking syscalls.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let parsed = Self.readSocks5Request(clientFd: clientFd) else {
                print("[socks5] handshake parse failed; closing")
                Darwin.close(clientFd)
                return
            }

            let cmdName: String
            switch parsed.cmd {
            case 0x01: cmdName = "CONNECT"
            case 0x02: cmdName = "BIND"
            case 0x03: cmdName = "UDP_ASSOCIATE"
            default: cmdName = "0x\(String(parsed.cmd, radix: 16))"
            }
            print("[socks5] CMD=\(cmdName) atyp=0x\(String(parsed.atyp, radix: 16))")

            switch parsed.cmd {
            case 0x01: // CONNECT
                Task { @MainActor in
                    self?.bridgeConnect(
                        clientFd: clientFd,
                        atyp: parsed.atyp,
                        addrBytes: parsed.addrBytes,
                        portBE: parsed.portBE
                    )
                }
            case 0x03: // UDP ASSOCIATE
                Task { @MainActor in
                    self?.startUdpAssociation(clientFd: clientFd)
                }
            default:
                Self.sendReply(clientFd, rep: 0x07) // command not supported
                Darwin.close(clientFd)
            }
        }
    }

    /// Reads greeting + request from the client and writes the greeting
    /// reply. Returns parsed CMD/ATYP/addr/port on success, `nil` on
    /// malformed input (in which case caller closes the socket).
    nonisolated private static func readSocks5Request(clientFd: Int32) -> ParsedRequest? {
        // Greeting: VER, NMETHODS, METHODS[NMETHODS]
        var greeting = [UInt8](repeating: 0, count: 2)
        guard readFully(clientFd, &greeting, 2), greeting[0] == 0x05 else { return nil }
        let nmethods = Int(greeting[1])
        if nmethods > 0 {
            var methods = [UInt8](repeating: 0, count: nmethods)
            guard readFully(clientFd, &methods, nmethods) else { return nil }
        }
        var greetingReply: [UInt8] = [0x05, 0x00] // NOAUTH
        guard writeFully(clientFd, &greetingReply, 2) else { return nil }

        // Request prefix: VER, CMD, RSV, ATYP
        var head = [UInt8](repeating: 0, count: 4)
        guard readFully(clientFd, &head, 4), head[0] == 0x05 else {
            sendReply(clientFd, rep: 0x01)
            return nil
        }
        let cmd = head[1]
        let atyp = head[3]

        var addrBytes: [UInt8] = []
        switch atyp {
        case 0x01: // IPv4
            addrBytes = [UInt8](repeating: 0, count: 4)
            guard readFully(clientFd, &addrBytes, 4) else {
                sendReply(clientFd, rep: 0x01); return nil
            }
        case 0x03: // DOMAIN
            var lenByte: [UInt8] = [0]
            guard readFully(clientFd, &lenByte, 1), lenByte[0] > 0 else {
                sendReply(clientFd, rep: 0x01); return nil
            }
            let nl = Int(lenByte[0])
            var name = [UInt8](repeating: 0, count: nl)
            guard readFully(clientFd, &name, nl) else {
                sendReply(clientFd, rep: 0x01); return nil
            }
            addrBytes = [UInt8(nl)] + name
        case 0x04: // IPv6
            addrBytes = [UInt8](repeating: 0, count: 16)
            guard readFully(clientFd, &addrBytes, 16) else {
                sendReply(clientFd, rep: 0x01); return nil
            }
        default:
            sendReply(clientFd, rep: 0x08) // address type not supported
            return nil
        }
        var portBE = [UInt8](repeating: 0, count: 2)
        guard readFully(clientFd, &portBE, 2) else {
            sendReply(clientFd, rep: 0x01); return nil
        }
        return ParsedRequest(cmd: cmd, atyp: atyp, addrBytes: addrBytes, portBE: portBE)
    }

    private struct ParsedRequest {
        let cmd: UInt8
        let atyp: UInt8
        let addrBytes: [UInt8]
        let portBE: [UInt8]
    }

    // MARK: - CONNECT path

    private func bridgeConnect(
        clientFd: Int32,
        atyp: UInt8,
        addrBytes: [UInt8],
        portBE: [UInt8]
    ) {
        guard let device else {
            Self.sendReply(clientFd, rep: 0x01)
            Darwin.close(clientFd)
            return
        }
        device.connect(toPort: guestTcpPort) { result in
            switch result {
            case let .success(conn):
                let vsockFd = conn.fileDescriptor
                DispatchQueue.global(qos: .utility).async {
                    // Replay greeting+request to guest's TCP SOCKS5; pipe its
                    // reply byte-for-byte to the client; then splice payload.
                    var greeting: [UInt8] = [0x05, 0x01, 0x00] // VER, NMETHODS=1, NOAUTH
                    guard Self.writeFully(vsockFd, &greeting, greeting.count) else {
                        Self.sendReply(clientFd, rep: 0x01)
                        Darwin.close(clientFd); _ = conn; return
                    }
                    var greetingResp = [UInt8](repeating: 0, count: 2)
                    guard Self.readFully(vsockFd, &greetingResp, 2),
                          greetingResp[0] == 0x05, greetingResp[1] == 0x00
                    else {
                        Self.sendReply(clientFd, rep: 0x01)
                        Darwin.close(clientFd); _ = conn; return
                    }
                    var request: [UInt8] = [0x05, 0x01, 0x00, atyp]
                    request.append(contentsOf: addrBytes)
                    request.append(contentsOf: portBE)
                    guard Self.writeFully(vsockFd, &request, request.count) else {
                        Self.sendReply(clientFd, rep: 0x01)
                        Darwin.close(clientFd); _ = conn; return
                    }
                    // Guest's send_reply always emits 10 bytes (BND ATYP=IPv4).
                    var reply = [UInt8](repeating: 0, count: 10)
                    guard Self.readFully(vsockFd, &reply, 10) else {
                        Self.sendReply(clientFd, rep: 0x01)
                        Darwin.close(clientFd); _ = conn; return
                    }
                    guard Self.writeFully(clientFd, &reply, 10) else {
                        Darwin.close(clientFd); _ = conn; return
                    }
                    if reply[1] != 0x00 {
                        Darwin.close(clientFd); _ = conn; return
                    }
                    Self.spliceBoth(a: clientFd, b: vsockFd) { _ = conn }
                }
            case let .failure(err):
                print("[socks5] vsock connect failed: \(err)")
                Self.sendReply(clientFd, rep: 0x01)
                Darwin.close(clientFd)
            }
        }
    }

    // MARK: - UDP ASSOCIATE path

    private func startUdpAssociation(clientFd: Int32) {
        guard let device else {
            Self.sendReply(clientFd, rep: 0x01)
            Darwin.close(clientFd)
            return
        }
        let guestUdpPort = self.guestUdpPort
        let listenHost = self.listenHost
        // Host UDP relay socket — clients send datagrams here; we forward
        // them framed over vsock to the guest.
        let udpFd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard udpFd >= 0 else {
            print("[socks5-udp] socket() failed: \(errnoString())")
            Self.sendReply(clientFd, rep: 0x01)
            Darwin.close(clientFd)
            return
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = inet_addr(listenHost)
        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(udpFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            print("[socks5-udp] bind failed: \(errnoString())")
            Darwin.close(udpFd)
            Self.sendReply(clientFd, rep: 0x01)
            Darwin.close(clientFd)
            return
        }
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(udpFd, sa, &boundLen)
            }
        }
        let boundPort = UInt16(bigEndian: bound.sin_port)
        print("[socks5-udp] association: host UDP relay on \(listenHost):\(boundPort)")

        device.connect(toPort: guestUdpPort) { result in
            switch result {
            case let .success(conn):
                let vsockFd = conn.fileDescriptor
                // Reply to client: BND.ADDR=0.0.0.0 (client reuses the TCP
                // server addr), BND.PORT = relay port.
                var reply: [UInt8] = [
                    0x05, 0x00, 0x00, 0x01,
                    0, 0, 0, 0,
                    UInt8((boundPort >> 8) & 0xff), UInt8(boundPort & 0xff),
                ]
                guard Self.writeFully(clientFd, &reply, 10) else {
                    Darwin.close(udpFd); Darwin.close(clientFd); _ = conn
                    return
                }
                Self.runUdpAssociation(
                    clientFd: clientFd,
                    udpFd: udpFd,
                    vsockFd: vsockFd,
                    holdConn: { _ = conn }
                )
            case let .failure(err):
                print("[socks5-udp] vsock connect failed: \(err)")
                Self.sendReply(clientFd, rep: 0x01)
                Darwin.close(udpFd)
                Darwin.close(clientFd)
            }
        }
    }

    /// Three-thread per-association coordinator:
    ///   1. TCP control reader — RFC 1928 §7: association lifetime = TCP.
    ///      Any EOF/error on the control channel tears the association down.
    ///   2. UDP → vsock — reads datagrams from the client, reframes as
    ///      `[u32 len][atyp][addr][port][payload]` and writes to vsock.
    ///   3. vsock → UDP — reads framed datagrams from the guest, wraps in
    ///      the RFC 1928 §7 UDP header (`[0,0,0][atyp][addr][port][payload]`),
    ///      sends back to the latched client source.
    nonisolated private static func runUdpAssociation(
        clientFd: Int32,
        udpFd: Int32,
        vsockFd: Int32,
        holdConn: @escaping () -> Void
    ) {
        let state = TeardownState()
        let clientAddr = ClientAddrBox()
        let q = DispatchQueue.global(qos: .utility)
        let group = DispatchGroup()

        let teardown: @Sendable () -> Void = {
            if state.fire() {
                // Shutdown wakes blocked reads on both stream sockets.
                // The UDP thread relies on its poll() timeout to notice
                // (Darwin shutdown() on unconnected UDP is ENOTCONN).
                _ = Darwin.shutdown(clientFd, SHUT_RDWR)
                _ = Darwin.shutdown(vsockFd, SHUT_RDWR)
            }
        }

        // Thread 1: TCP control reader (no protocol on this channel after
        // ASSOCIATE; client typically half-closes when done — anything else
        // is treated as session end).
        group.enter()
        q.async {
            var sink = [UInt8](repeating: 0, count: 256)
            while !state.isStopped {
                let n = sink.withUnsafeMutableBufferPointer { bp in
                    Darwin.read(clientFd, bp.baseAddress, bp.count)
                }
                if n <= 0 { break }
            }
            teardown()
            group.leave()
        }

        // Thread 2: UDP → vsock.
        group.enter()
        q.async {
            var pkt = [UInt8](repeating: 0, count: 65535)
            while !state.isStopped {
                if !waitReadable(udpFd, timeoutMs: 500) { continue }
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n: ssize_t = pkt.withUnsafeMutableBufferPointer { bp in
                    withUnsafeMutablePointer(to: &src) { sp in
                        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.recvfrom(udpFd, bp.baseAddress, bp.count, 0, sa, &srcLen)
                        }
                    }
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // SOCKS5 UDP header (RFC 1928 §7):
                //   [RSV 2][FRAG 1][ATYP 1][DST.ADDR var][DST.PORT 2][DATA var]
                // Minimum (IPv4, no payload): 10 bytes.
                if n < 10 || pkt[0] != 0x00 || pkt[1] != 0x00 { continue }
                if pkt[2] != 0x00 { continue } // FRAG unsupported per RFC
                let atyp = pkt[3]
                let addrLen: Int
                switch atyp {
                case 0x01: addrLen = 4
                case 0x03:
                    if Int(n) < 5 { continue }
                    addrLen = 1 + Int(pkt[4])
                case 0x04: addrLen = 16
                default: continue
                }
                let headerEnd = 4 + addrLen + 2
                if Int(n) < headerEnd { continue }

                // Body to ship to guest = [atyp][addr][port][payload].
                // That's exactly pkt[3 ..< n].
                let bodyStart = 3
                let bodyLen = Int(n) - bodyStart

                clientAddr.set(src)

                var lenBuf: [UInt8] = [
                    UInt8((bodyLen >> 24) & 0xff),
                    UInt8((bodyLen >> 16) & 0xff),
                    UInt8((bodyLen >> 8) & 0xff),
                    UInt8(bodyLen & 0xff),
                ]
                if !writeFully(vsockFd, &lenBuf, 4) { break }
                let bodyOk: Bool = pkt.withUnsafeBufferPointer { bp in
                    guard let base = bp.baseAddress else { return false }
                    return writeFully(vsockFd, base.advanced(by: bodyStart), bodyLen)
                }
                if !bodyOk { break }
            }
            teardown()
            group.leave()
        }

        // Thread 3: vsock → UDP.
        group.enter()
        q.async {
            while !state.isStopped {
                var lenBuf = [UInt8](repeating: 0, count: 4)
                if !readFully(vsockFd, &lenBuf, 4) { break }
                let len = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16)
                    | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
                if len == 0 || len > 65535 { break }
                var body = [UInt8](repeating: 0, count: Int(len))
                if !readFully(vsockFd, &body, Int(len)) { break }
                guard var dst = clientAddr.get() else {
                    // Reply arrived but no client source latched yet — drop.
                    continue
                }
                // body already = [atyp][addr][port][payload]; prepend SOCKS5
                // UDP header (RSV=0,0 + FRAG=0).
                var out = [UInt8]()
                out.reserveCapacity(3 + body.count)
                out.append(0x00); out.append(0x00); out.append(0x00)
                out.append(contentsOf: body)
                _ = withUnsafePointer(to: &dst) { ptr -> ssize_t in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        out.withUnsafeBufferPointer { bp in
                            Darwin.sendto(udpFd, bp.baseAddress, bp.count, 0, sa,
                                          socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            teardown()
            group.leave()
        }

        group.notify(queue: q) {
            Darwin.close(clientFd)
            Darwin.close(udpFd)
            Darwin.close(vsockFd)
            holdConn()
        }
    }

    // MARK: - Byte splice (CONNECT)

    nonisolated private static func spliceBoth(a: Int32, b: Int32, onDone: @escaping () -> Void) {
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .utility)

        group.enter()
        q.async {
            pump(from: a, to: b)
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

    // MARK: - I/O helpers

    nonisolated private static func readFully(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = Darwin.read(fd, buf.advanced(by: off), n - off)
            if r <= 0 { return false }
            off += r
        }
        return true
    }

    nonisolated private static func readFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        buf.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return false }
            return readFully(fd, base, n)
        }
    }

    nonisolated private static func writeFully(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let w = Darwin.write(fd, buf.advanced(by: off), n - off)
            if w <= 0 { return false }
            off += w
        }
        return true
    }

    nonisolated private static func writeFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        buf.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return false }
            return writeFully(fd, base, n)
        }
    }

    /// Wait up to `timeoutMs` for `fd` to be readable. Used by the UDP→vsock
    /// thread so it can periodically observe the teardown flag without
    /// blocking forever on recvfrom (Darwin shutdown() on unconnected UDP
    /// sockets returns ENOTCONN, so it can't wake recv from another thread).
    nonisolated private static func waitReadable(_ fd: Int32, timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, timeoutMs) }
        return rc > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    /// Generic SOCKS5 failure reply (BND IPv4 0.0.0.0:0).
    nonisolated private static func sendReply(_ fd: Int32, rep: UInt8) {
        var r: [UInt8] = [0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        _ = writeFully(fd, &r, 10)
    }

    nonisolated private func errnoString() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - Cross-thread state

/// Once-fire teardown flag, observed by all three association threads.
private final class TeardownState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Sets the flag if not already set. Returns true on the first call only.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        stopped = true
        return true
    }
}

/// Latched client UDP source. The vsock→UDP thread reads it to know where to
/// send replies; the UDP→vsock thread writes it on every received datagram.
/// Surge keeps a stable source port per association, so the last-seen value
/// is the right one to reply to.
private final class ClientAddrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var addr: sockaddr_in?

    func set(_ a: sockaddr_in) {
        lock.lock(); defer { lock.unlock() }
        addr = a
    }

    func get() -> sockaddr_in? {
        lock.lock(); defer { lock.unlock() }
        return addr
    }
}
