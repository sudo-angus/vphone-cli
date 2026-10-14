import Foundation
import Virtualization
import VPhoneCoreKit

/// Host adapter for an imported, authenticated 1.x device. The guest and its
/// installed daemon remain untouched; only supported operations are mapped.
@MainActor
final class VPhoneLegacyGuestControl {
    private var connection: VZVirtioSocketConnection?
    private var session: VPhoneLegacyGuestSession?
    private var opening: Task<VPhoneLegacyGuestSession, Error>?
    private(set) var hello: [String: Any] = [:]

    func stop() {
        opening?.cancel()
        opening = nil
        session?.stop()
        session = nil
        connection = nil
        hello = [:]
    }

    private func connect(_ device: VZVirtioSocketDevice) async throws -> VPhoneLegacyGuestSession {
        if let session { return session }
        if let opening { return try await opening.value }
        let task = Task { @MainActor in
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<LegacySocketResult, Never>) in
                let completion = LegacySocketCompletion(continuation)
                device.connect(toPort: 1337) { completion.finish(LegacySocketResult($0)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    completion.finish(LegacySocketResult(.failure(VPhoneLegacyGuestSession.Failure("Legacy VSOCK connect timed out"))))
                }
            }
            let connected = try result.value.get()
            guard !Task.isCancelled else { throw CancellationError() }
            let session = try VPhoneLegacyGuestSession(fileDescriptor: connected.fileDescriptor)
            self.connection = connected
            self.session = session
            return session
        }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    func send(_ request: [String: Any], payload: Data? = nil, device: VZVirtioSocketDevice) async throws -> ([String: Any], Data?) {
        let allowed: Set<String> = [
            "ping", "version", "hid", "touch", "shake", "devmode", "location", "location_stop",
            "file_list", "file_get", "file_put", "file_mkdir", "file_delete", "file_rename",
            "clipboard_get", "clipboard_set", "ipa_install", "app_list", "app_launch", "app_terminate",
            "app_uninstall", "open_url", "settings_get", "settings_set", "low_power_mode",
            "keychain_list", "keychain_get", "keychain_add", "keychain_update", "keychain_delete",
        ]
        guard let type = request["t"] as? String, allowed.contains(type) else {
            throw VPhoneGuestControl.ControlError.unsupportedCapability(request["t"] as? String ?? "legacy operation")
        }
        var object = request
        object["v"] = 1
        object["id"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: object)
        let reply: VPhoneLegacyGuestSession.Reply
        do { reply = try await connect(device).exchange(data, payload: payload) }
        catch { stop(); throw error }
        hello = try JSONSerialization.jsonObject(with: reply.hello) as? [String: Any] ?? [:]
        return (try Self.decodeReply(reply.json), reply.binary)
    }

    static func decodeReply(_ data: Data) throws -> [String: Any] {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VPhoneGuestControl.ControlError.protocolError("invalid legacy JSON")
        }
        if value["t"] as? String == "err" || value["ok"] as? Bool == false {
            var error = value
            error["code"] = value["code"] ?? "legacy_guest_error"
            error["message"] = value["error"] as? String ?? value["msg"] as? String
                ?? value["message"] as? String ?? "Legacy guest refused operation"
            throw VPhoneGuestControl.GuestRPCFailure(body: error)
        }
        value["ok"] = value["ok"] ?? true
        return value
    }

    func health(device: VZVirtioSocketDevice) async throws -> [String: Any] {
        _ = try await send(["t": "ping"], device: device)
        let aliases = ["file": "files", "shake": "motion_shake"]
        let capabilities = (hello["caps"] as? [String] ?? []).map { aliases[$0] ?? $0 }
        var info: [String: Any] = ["api_version": 1, "status": "ok", "capabilities": capabilities,
                                   "ios": hello["ios"] as? String ?? "unknown", "binary_hash": "legacy-preserved",
                                   "instance": "legacy-preserved"]
        // The old daemon pins this NAT alias for its direct SOCKS endpoint.
        // Learn that address for host forwarding without changing guest routes.
        if let endpoint = hello["socks5_tcp"] as? String, let host = endpoint.split(separator: ":").first,
           VPhoneIPv4Address(dotted: String(host)) != nil {
            info["ip"] = String(host)
            info["socks5_tcp"] = endpoint
        } else { info["ip"] = hello["ip"] }
        return info
    }

    func call(_ method: String, params: [String: Any], device: VZVirtioSocketDevice) async throws -> [String: Any] {
        let operations = [
            "input.hid": "hid", "input.touch": "touch", "input.shake": "shake",
            "developer_mode.status": "devmode", "developer_mode.enable": "devmode",
            "apps.list": "app_list", "apps.launch": "app_launch", "apps.terminate": "app_terminate",
            "apps.uninstall": "app_uninstall", "apps.open_url": "open_url", "apps.install": "ipa_install",
            "clipboard.get": "clipboard_get", "clipboard.set": "clipboard_set",
            "files.list": "file_list", "files.mkdir": "file_mkdir", "files.remove": "file_delete", "files.rename": "file_rename",
            "settings.get": "settings_get", "settings.set": "settings_set", "power.low_power_mode": "low_power_mode",
            "keychain.list": "keychain_list", "keychain.get": "keychain_get", "keychain.add": "keychain_add",
            "keychain.update": "keychain_update", "keychain.delete": "keychain_delete",
            "location.set": "location", "location.clear": "location_stop",
        ]
        guard let type = operations[method] else { throw VPhoneGuestControl.ControlError.unsupportedCapability(method) }
        var request = params
        request["t"] = type
        if type == "devmode" { request["action"] = method == "developer_mode.status" ? "status" : "enable" }
        if type == "touch" {
            let phase = params["phase"] as? String ?? ""
            guard let index = ["down": 0, "move": 1, "up": 2][phase] else { throw VPhoneGuestControl.ControlError.protocolError("invalid touch phase") }
            request["phase"] = index
        }
        if type == "location" {
            for (new, old) in [("latitude", "lat"), ("longitude", "lon"), ("altitude", "alt"), ("horizontal_accuracy", "hacc"), ("vertical_accuracy", "vacc")] {
                request[old] = params[new]
            }
        }
        return try await send(request, device: device).0
    }
}

private struct LegacySocketResult: @unchecked Sendable {
    let value: Result<VZVirtioSocketConnection, Error>
    init(_ value: Result<VZVirtioSocketConnection, Error>) { self.value = value }
}

/// A VZ connect can finish after the deadline. Resume at most once; a late
/// connection is released instead of starting a second legacy client.
private final class LegacySocketCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LegacySocketResult, Never>?
    init(_ continuation: CheckedContinuation<LegacySocketResult, Never>) { self.continuation = continuation }
    func finish(_ result: LegacySocketResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
