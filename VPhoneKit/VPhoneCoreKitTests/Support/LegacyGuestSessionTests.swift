import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

struct LegacyGuestSessionTests {
    private struct PeerFailure: Error {}
    private static func read(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                guard n > 0 else { throw PeerFailure() }
                offset += n
            }
        }
        return data
    }
    private static func frame(_ fd: Int32) throws -> [String: Any] {
        let header = try read(fd, 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        return try #require(JSONSerialization.jsonObject(with: read(fd, count)) as? [String: Any])
    }
    private static func write(_ fd: Int32, object: [String: Any], binary: Data = Data()) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(data.count).bigEndian
        let packet = withUnsafeBytes(of: &length) { Data($0) } + data + binary
        // Fragment both headers and binary payload deliberately.
        for byte in packet { var byte = byte; guard Darwin.write(fd, &byte, 1) == 1 else { throw PeerFailure() } }
    }
    private func sockets() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw PeerFailure() }
        for fd in fds { var one: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        return (fds[0], fds[1])
    }
    private func request(_ type: String, id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "t": type, "id": id])
    }

    @Test func `one handshake and concurrent binary replies keep the stream aligned`() async throws {
        let (host, guest) = try sockets()
        defer { close(host) }
        let session = try VPhoneLegacyGuestSession(fileDescriptor: host, timeout: 3)
        defer { session.stop() }
        let peer = Task.detached {
            defer { close(guest) }
            let hello = try Self.frame(guest)
            #expect(hello["t"] as? String == "hello")
            #expect(hello["bin_hash"] == nil)
            try Self.write(guest, object: ["v": 1, "t": "hello", "caps": ["file", "clipboard"]])
            for _ in 0 ..< 2 {
                let request = try Self.frame(guest)
                let id = try #require(request["id"] as? String)
                if request["t"] as? String == "file_get" {
                    try Self.write(guest, object: ["v": 1, "t": "file_data", "id": id, "size": 4], binary: Data([1, 2, 3, 4]))
                } else {
                    try Self.write(guest, object: ["v": 1, "t": "clipboard_get", "id": id, "has_image": true, "image_size": 3], binary: Data([9, 8, 7]))
                }
            }
        }
        async let file = session.exchange(request("file_get", id: "file"))
        async let clipboard = session.exchange(request("clipboard_get", id: "clipboard"))
        let replies = try await (file, clipboard)
        #expect(replies.0.binary == Data([1, 2, 3, 4]))
        #expect(replies.1.binary == Data([9, 8, 7]))
        try await peer.value
    }

    @Test func `upload sends raw bytes before reply and guest error remains readable`() async throws {
        let (host, guest) = try sockets()
        defer { close(host) }
        let session = try VPhoneLegacyGuestSession(fileDescriptor: host, timeout: 3)
        defer { session.stop() }
        let peer = Task.detached {
            defer { close(guest) }
            _ = try Self.frame(guest)
            try Self.write(guest, object: ["v": 1, "t": "hello"])
            let upload = try Self.frame(guest)
            #expect(try Self.read(guest, 4) == Data([5, 6, 7, 8]))
            try Self.write(guest, object: ["v": 1, "t": "err", "id": upload["id"]!, "msg": "read-only file"])
            let ping = try Self.frame(guest)
            try Self.write(guest, object: ["v": 1, "t": "pong", "id": ping["id"]!])
        }
        let response = try await session.exchange(request("file_put", id: "put"), payload: Data([5, 6, 7, 8]))
        #expect(try (JSONSerialization.jsonObject(with: response.json) as? [String: Any])?["t"] as? String == "err")
        _ = try await session.exchange(request("ping", id: "ping"))
        try await peer.value
    }

    @Test func `silent peer times out and closed sessions reject queued calls`() async throws {
        let (host, guest) = try sockets()
        defer { close(host); close(guest) }
        let session = try VPhoneLegacyGuestSession(fileDescriptor: host, timeout: 0.05)
        let started = ProcessInfo.processInfo.systemUptime
        await #expect(throws: VPhoneLegacyGuestSession.Failure.self) { _ = try await session.exchange(request("ping", id: "first")) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        await #expect(throws: VPhoneLegacyGuestSession.Failure.self) { _ = try await session.exchange(request("ping", id: "next")) }
    }
}
