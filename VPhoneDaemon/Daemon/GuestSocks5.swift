import CoreFoundation
import Darwin
import Foundation
import VphonedNative

/// Saved on the guest's data volume. The host configures it over the existing
/// RPC API; traffic and DNS are handled by guest sockets and follow its VPN.
final class GuestSocks5: @unchecked Sendable {
    static let shared = GuestSocks5()
    private let lock = NSLock()
    private let saveURL: URL
    private var savedPort: UInt16 = 0

    init(saveURL: URL = URL(fileURLWithPath: "/var/root/Library/Preferences/com.vphone.vphoned.socks5.plist")) {
        self.saveURL = saveURL
    }

    func describe() -> [String: Any] {
        lock.withLock { status() }
    }

    func configure(_ params: [String: Any]) throws -> [String: Any] {
        guard let number = params["port"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue == 0 || (1024 ... 65535).contains(number.intValue)
        else { throw GuestAPIError.invalidRequest("port must be 0 (off) or an integer from 1024 to 65535") }
        let port = UInt16(number.intValue)
        return try lock.withLock {
            let previous = vp_socks5_port()
            let error = vp_socks5_set_port(port)
            guard error == 0 else {
                throw GuestAPIError.operationFailed("SOCKS5 could not bind port \(port): \(String(cString: strerror(error)))")
            }
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: ["port": Int(port)], format: .binary, options: 0)
                try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: saveURL, options: .atomic)
                savedPort = port
            } catch {
                let rollback = vp_socks5_set_port(previous)
                throw GuestAPIError.operationFailed("SOCKS5 configuration was not saved: \(error); rollback errno=\(rollback)")
            }
            return status()
        }
    }

    func restoreOnStartup() {
        lock.withLock {
            guard let data = try? Data(contentsOf: saveURL),
                  let record = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Int],
                  let port = record["port"], port == 0 || (1024 ... 65535).contains(port)
            else { return }
            savedPort = UInt16(port)
            let error = vp_socks5_set_port(savedPort)
            if error != 0 { NSLog("vphoned: SOCKS5 startup failed: %s", strerror(error)) }
        }
    }

    private func status() -> [String: Any] {
        let port = vp_socks5_port()
        return ["port": Int(port), "saved_port": Int(savedPort), "enabled": port != 0, "transport": "tcp-ip", "udp_associate": true]
    }
}

extension GuestAPI {
    static func executeSocks5(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "network.socks5.get": return GuestSocks5.shared.describe()
        case "network.socks5.set": return try GuestSocks5.shared.configure(params)
        default: return nil
        }
    }
}
