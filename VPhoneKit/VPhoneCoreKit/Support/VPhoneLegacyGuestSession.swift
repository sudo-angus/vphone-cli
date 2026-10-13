import Darwin
import Foundation

/// The 1.x length-prefixed protocol. One queue owns the stream, including every
/// inline binary tail: concurrent callers must never steal each other's bytes.
/// This client intentionally has no daemon-update operation or hello bin_hash.
public final class VPhoneLegacyGuestSession: @unchecked Sendable {
    public struct Reply: Sendable {
        public let json: Data
        public let binary: Data?
        public let hello: Data
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "com.vphone.legacy-guest")
    private let state = NSLock()
    private var stopped = false
    // Used only on queue.
    private var hello: Data?
    private let timeout: TimeInterval
    private static let maxJSON = 1024 * 1024
    private static let maxBinary = 256 * 1024 * 1024

    public init(fileDescriptor: Int32, timeout: TimeInterval = 30) throws {
        fd = dup(fileDescriptor)
        guard fd >= 0 else { throw Failure("Cannot duplicate legacy guest socket: \(errno)") }
        self.timeout = timeout
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { Darwin.close(fd) }

    /// shutdown wakes in-flight I/O; the descriptor stays owned until every
    /// queued exchange releases this session, so its number cannot be reused.
    public func stop() {
        state.lock()
        if !stopped { stopped = true; _ = shutdown(fd, SHUT_RDWR) }
        state.unlock()
    }

    public func exchange(_ request: Data, payload: Data? = nil) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.state.lock()
                    let stopped = self.stopped
                    self.state.unlock()
                    guard !stopped else { throw Failure("Legacy guest socket is closed") }
                    guard request.count <= Self.maxJSON, (payload?.count ?? 0) <= Self.maxBinary else {
                        throw Failure("Legacy guest request exceeds transfer limit")
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + self.timeout
                    if self.hello == nil {
                        try self.writeFrame(Data(#"{"v":1,"t":"hello"}"#.utf8), deadline: deadline)
                        let greeting = try self.readFrame(deadline: deadline)
                        guard let value = try JSONSerialization.jsonObject(with: greeting) as? [String: Any],
                              value["v"] as? Int == 1, value["t"] as? String == "hello"
                        else { throw Failure("Incompatible legacy guest handshake") }
                        self.hello = greeting
                    }
                    try self.writeFrame(request, deadline: deadline)
                    if let payload { try self.writeAll(payload, deadline: deadline) }
                    let json = try self.readFrame(deadline: deadline)
                    guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                          object["v"] as? Int == 1, let type = object["t"] as? String,
                          let sent = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                          object["id"] as? String == sent["id"] as? String
                    else { throw Failure("Invalid legacy guest response") }
                    let count: Int
                    if type == "file_data" {
                        guard let size = object["size"] as? Int else { throw Failure("Missing file length") }
                        count = size
                    } else if type == "clipboard_get", object["has_image"] as? Bool == true {
                        guard let size = object["image_size"] as? Int else { throw Failure("Missing clipboard length") }
                        count = size
                    } else { count = 0 }
                    guard count >= 0, count <= Self.maxBinary else { throw Failure("Invalid legacy binary length") }
                    let binary = (type == "file_data" || count > 0) ? try self.readAll(count, deadline: deadline) : nil
                    continuation.resume(returning: Reply(json: json, binary: binary, hello: self.hello!))
                } catch {
                    self.stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func wait(_ events: Int16, deadline: TimeInterval) throws {
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw Failure("Legacy guest request timed out") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(left * 1000 + 1, 1000)))
            if ready > 0 {
                if descriptor.revents & events != 0 { return }
                throw Failure("Legacy guest socket closed")
            }
            if ready < 0, errno != EINTR { throw Failure("Legacy guest poll failed: \(errno)") }
        }
    }

    private func readAll(_ count: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(Int16(POLLIN), deadline: deadline)
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n > 0 { offset += n }
                else if n < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw Failure("Legacy guest read failed: \(n == 0 ? "EOF" : String(errno))") }
            }
        }
        return data
    }

    private func writeAll(_ data: Data, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(Int16(POLLOUT), deadline: deadline)
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if n > 0 { offset += n }
                else if n < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw Failure("Legacy guest write failed: \(errno)") }
            }
        }
    }

    private func readFrame(deadline: TimeInterval) throws -> Data {
        let header = try readAll(4, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Self.maxJSON else { throw Failure("Invalid legacy JSON length") }
        return try readAll(count, deadline: deadline)
    }

    private func writeFrame(_ data: Data, deadline: TimeInterval) throws {
        var length = UInt32(data.count).bigEndian
        try writeAll(withUnsafeBytes(of: &length) { Data($0) }, deadline: deadline)
        try writeAll(data, deadline: deadline)
    }
}
