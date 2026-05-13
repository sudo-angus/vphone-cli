import Darwin
import Foundation

/// Native usbmux TCP port forwarder.
///
/// This speaks the plist usbmuxd protocol directly over `/var/run/usbmuxd`,
/// selects the VM by predicted UDID/ECID, and then byte-splices each accepted
/// local TCP connection into the device port returned by usbmuxd.
@MainActor
final class VPhoneUSBMuxForwarder {
    private let listenHost: String
    private let listenPort: UInt16
    private let targetPort: UInt16
    private let targetUDID: String?
    private let targetECID: String?
    private let usbmuxPath: String
    private var listenFd: Int32 = -1

    init(
        listenHost: String = "127.0.0.1",
        listenPort: UInt16,
        targetPort: UInt16,
        targetUDID: String?,
        targetECID: String?,
        usbmuxPath: String = "/var/run/usbmuxd"
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.targetPort = targetPort
        self.targetUDID = targetUDID
        self.targetECID = targetECID
        self.usbmuxPath = usbmuxPath
    }

    func start() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[usbmux] socket() failed: \(Self.errnoString())")
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
            print("[usbmux] bind \(listenHost):\(listenPort) failed: \(Self.errnoString()); forwarding disabled")
            Darwin.close(fd)
            return
        }
        guard Darwin.listen(fd, 32) == 0 else {
            print("[usbmux] listen failed: \(Self.errnoString()); forwarding disabled")
            Darwin.close(fd)
            return
        }

        listenFd = fd
        let target = targetUDID ?? targetECID.map { "ECID \($0)" } ?? "first available device"
        print("[usbmux] native forward listening on \(listenHost):\(listenPort) -> \(target):\(targetPort)")

        DispatchQueue(label: "vphone.usbmux.forward.accept", qos: .utility).async { [weak self] in
            self?.runAcceptLoop(fd: fd)
        }
    }

    func stop() {
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
            var one: Int32 = 1
            _ = Darwin.setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            Task { @MainActor [weak self] in
                self?.handle(clientFd: client)
            }
        }
    }

    private func handle(clientFd: Int32) {
        let targetUDID = self.targetUDID
        let targetECID = self.targetECID
        let targetPort = self.targetPort
        let usbmuxPath = self.usbmuxPath

        DispatchQueue.global(qos: .utility).async {
            do {
                let remoteFd = try Self.resolveAndConnectRemote(
                    targetUDID: targetUDID,
                    targetECID: targetECID,
                    targetPort: targetPort,
                    usbmuxPath: usbmuxPath,
                    timeout: 45
                )
                print("[usbmux] connection established -> guest:\(targetPort)")
                Self.spliceBoth(a: clientFd, b: remoteFd) {
                    Darwin.close(clientFd)
                    Darwin.close(remoteFd)
                }
            } catch {
                print("[usbmux] connect failed: \(error)")
                Darwin.close(clientFd)
            }
        }
    }

    // MARK: - Device resolution

    nonisolated private static func resolveAndConnectRemote(
        targetUDID: String?,
        targetECID: String?,
        targetPort: UInt16,
        usbmuxPath: String,
        timeout: TimeInterval
    ) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        repeat {
            do {
                let devices = try listDevices(usbmuxPath: usbmuxPath)
                if let device = selectDevice(devices, targetUDID: targetUDID, targetECID: targetECID) {
                    do {
                        return try connectToDevice(device, port: targetPort, usbmuxPath: usbmuxPath)
                    } catch {
                        lastError = error
                    }
                } else {
                    lastError = USBMuxError.deviceNotFound(describeTarget(udid: targetUDID, ecid: targetECID))
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 1.0)
        } while Date() < deadline

        throw lastError ?? USBMuxError.deviceNotFound(describeTarget(udid: targetUDID, ecid: targetECID))
    }

    nonisolated private static func selectDevice(
        _ devices: [USBMuxDevice],
        targetUDID: String?,
        targetECID: String?
    ) -> USBMuxDevice? {
        let usbDevices = devices.filter { $0.connectionType == "USB" }
        let candidates = usbDevices.isEmpty ? devices : usbDevices

        if let targetUDID {
            let matched = candidates.filter { normalizedUDID($0.serial) == normalizedUDID(targetUDID) }
            if let first = matched.first { return first }
        }

        if let targetECID {
            let ecid = normalizedECID(targetECID)
            let matched = candidates.filter { normalizedUDID($0.serial).contains(ecid) }
            if matched.count == 1 { return matched[0] }
        }

        if targetUDID == nil, targetECID == nil, candidates.count == 1 {
            return candidates[0]
        }

        return nil
    }

    private struct USBMuxDevice: Sendable {
        let deviceID: Int
        let serial: String
        let connectionType: String
    }

    // MARK: - usbmux plist protocol

    nonisolated private static func listDevices(usbmuxPath: String) throws -> [USBMuxDevice] {
        let fd = try connectControlSocket(path: usbmuxPath)
        defer { Darwin.close(fd) }

        try sendPlist(fd, tag: 1, payload: ["MessageType": "ListDevices"])
        let response = try receivePlist(fd, expectedTag: 1)

        guard let rawList = response["DeviceList"] as? [Any] else {
            throw USBMuxError.invalidResponse("missing DeviceList")
        }

        var devices: [USBMuxDevice] = []
        for rawItem in rawList {
            guard let item = rawItem as? [String: Any],
                  let deviceID = intValue(item["DeviceID"]),
                  let properties = item["Properties"] as? [String: Any],
                  let serial = properties["SerialNumber"] as? String
            else {
                continue
            }
            let connectionType = properties["ConnectionType"] as? String ?? "USB"
            devices.append(USBMuxDevice(deviceID: deviceID, serial: serial, connectionType: connectionType))
        }
        return devices
    }

    nonisolated private static func connectToDevice(
        _ device: USBMuxDevice,
        port: UInt16,
        usbmuxPath: String
    ) throws -> Int32 {
        let fd = try connectControlSocket(path: usbmuxPath)
        do {
            try sendPlist(
                fd,
                tag: 1,
                payload: [
                    "MessageType": "Connect",
                    "DeviceID": device.deviceID,
                    "PortNumber": Int(port.bigEndian),
                ]
            )
            let response = try receivePlist(fd, expectedTag: 1)
            guard response["MessageType"] as? String == "Result" else {
                throw USBMuxError.invalidResponse("unexpected Connect response: \(response)")
            }
            let number = intValue(response["Number"]) ?? -1
            guard number == 0 else {
                throw USBMuxError.connectRejected(number)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    nonisolated private static func connectControlSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw USBMuxError.socket("socket(AF_UNIX) failed: \(errnoString())")
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let copied = path.withCString { cPath -> Bool in
            guard strlen(cPath) < maxPath else { return false }
            return withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dest in
                    memset(dest, 0, maxPath)
                    strncpy(dest, cPath, maxPath - 1)
                    return true
                }
            }
        }
        guard copied else {
            Darwin.close(fd)
            throw USBMuxError.socket("usbmuxd path is too long: \(path)")
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = errnoString()
            Darwin.close(fd)
            throw USBMuxError.socket("connect \(path) failed: \(message)")
        }

        return fd
    }

    nonisolated private static func sendPlist(_ fd: Int32, tag: UInt32, payload: [String: Any]) throws {
        var request: [String: Any] = [
            "ClientVersionString": "vphone-cli",
            "ProgName": "vphone-cli",
            "kLibUSBMuxVersion": 3,
        ]
        for (key, value) in payload {
            request[key] = value
        }

        let body = try PropertyListSerialization.data(
            fromPropertyList: request,
            format: .xml,
            options: 0
        )

        var packet = Data()
        appendUInt32LE(UInt32(16 + body.count), to: &packet)
        appendUInt32LE(1, to: &packet) // usbmuxd plist protocol
        appendUInt32LE(8, to: &packet) // plist message
        appendUInt32LE(tag, to: &packet)
        packet.append(body)

        let ok = packet.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return writeFully(fd, base, packet.count)
        }
        guard ok else {
            throw USBMuxError.socket("write to usbmuxd failed: \(errnoString())")
        }
    }

    nonisolated private static func receivePlist(_ fd: Int32, expectedTag: UInt32) throws -> [String: Any] {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        guard readFully(fd, &lengthBytes, 4) else {
            throw USBMuxError.socket("read usbmuxd length failed: \(errnoString())")
        }

        let length = Int(readUInt32LE(lengthBytes, 0))
        guard (16 ... 16 * 1024 * 1024).contains(length) else {
            throw USBMuxError.invalidResponse("invalid packet length \(length)")
        }

        var payload = [UInt8](repeating: 0, count: length - 4)
        guard readFully(fd, &payload, payload.count) else {
            throw USBMuxError.socket("read usbmuxd payload failed: \(errnoString())")
        }

        let version = readUInt32LE(payload, 0)
        let message = readUInt32LE(payload, 4)
        let tag = readUInt32LE(payload, 8)
        guard version == 1, message == 8 else {
            throw USBMuxError.invalidResponse("expected plist response, got version=\(version) message=\(message)")
        }
        guard tag == expectedTag else {
            throw USBMuxError.invalidResponse("reply tag mismatch: expected \(expectedTag), got \(tag)")
        }

        let body = Data(payload.dropFirst(12))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: body, options: [], format: &format)
        guard let dict = plist as? [String: Any] else {
            throw USBMuxError.invalidResponse("plist body is not a dictionary")
        }
        return dict
    }

    // MARK: - Byte splice

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

        group.notify(queue: q, execute: onDone)
    }

    nonisolated private static func pump(from src: Int32, to dst: Int32) {
        let bufSize = 16 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = Darwin.read(src, buf, bufSize)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return }
            if !writeFully(dst, buf, n) { return }
        }
    }

    // MARK: - Helpers

    nonisolated private static func readFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        buf.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return false }
            return readFully(fd, base, n)
        }
    }

    nonisolated private static func readFully(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = Darwin.read(fd, buf.advanced(by: off), n - off)
            if r < 0, errno == EINTR { continue }
            if r <= 0 { return false }
            off += r
        }
        return true
    }

    nonisolated private static func writeFully(_ fd: Int32, _ buf: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let w = Darwin.write(fd, buf.advanced(by: off), n - off)
            if w < 0, errno == EINTR { continue }
            if w <= 0 { return false }
            off += w
        }
        return true
    }

    nonisolated private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            data.append(contentsOf: raw)
        }
    }

    nonisolated private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    nonisolated private static func normalizedUDID(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    nonisolated private static func normalizedECID(_ value: String) -> String {
        var raw = value.lowercased()
        if raw.hasPrefix("0x") {
            raw.removeFirst(2)
        }
        return raw.replacingOccurrences(of: "-", with: "")
    }

    nonisolated private static func describeTarget(udid: String?, ecid: String?) -> String {
        if let udid { return "UDID \(udid)" }
        if let ecid { return "ECID \(ecid)" }
        return "first available usbmux device"
    }

    nonisolated private static func errnoString() -> String {
        String(cString: strerror(errno))
    }

    private enum USBMuxError: Error, CustomStringConvertible, LocalizedError {
        case socket(String)
        case invalidResponse(String)
        case deviceNotFound(String)
        case connectRejected(Int)

        var description: String {
            switch self {
            case let .socket(message): message
            case let .invalidResponse(message): "invalid usbmux response: \(message)"
            case let .deviceNotFound(target): "target not visible on usbmuxd: \(target)"
            case let .connectRejected(number): "device rejected port connect (usbmux result \(number))"
            }
        }

        var errorDescription: String? {
            description
        }
    }
}
