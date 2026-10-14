import AppKit
import Foundation
import ImageIO
import Virtualization
import VPhoneCoreKit

// Compile the production socket server and image encoder with guest/display
// doubles, so regression tests never boot or interrupt an authenticated VM.
// Health discovery is outside this suite; only the legacy reply parser runs.
struct VPhoneIPv4Address {
    init?(dotted: String) { return nil }
}

@MainActor
final class VPhoneGuestControl {
    enum ControlError: Error {
        case notConnected
        case unsupportedCapability(String)
        case protocolError(String)
    }

    struct GuestRPCFailure: Error, @unchecked Sendable {
        let body: [String: Any]
        var message: String { body["message"] as? String ?? "Guest operation failed" }
    }

    var isConnected = true
    var guestCapabilities = ["touch"]
    var requests: [(String, [String: Any])] = []
    var failure: GuestRPCFailure?
    var screenshotData: Data?
    var screenshotRequests = 0
    var installedURL: URL?

    func rpcAfterQueuedInput(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        requests.append((method, params))
        if let failure { throw failure }
        switch method {
        case "apps.list":
            return ["apps": [["bundle_id": "com.apple.Preferences", "name": "Settings", "type": "system",
                              "state": "running", "pid": 123, "version": "1.0"]]]
        case "apps.launch": return ["pid": 123, "frontmost_verified": true]
        case "clipboard.get": return ["text": "clipboard", "has_image": false]
        default: return [:]
        }
    }

    func callAfterQueuedInput(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try await rpcAfterQueuedInput(method, params: params)
    }

    func installIPAResult(localURL: URL) async throws -> [String: Any] {
        installedURL = localURL
        if let failure { throw failure }
        return ["bundle_id": "test.installed", "msg": "Installed test.installed"]
    }

    func sendPing() async throws {
        if let failure { throw failure }
    }

    func screenshotJPEG() async throws -> Data {
        screenshotRequests += 1
        guard let screenshotData else {
            throw GuestRPCFailure(body: ["code": "unsupported", "message": "guest does not support capability: screen.screenshot"])
        }
        return screenshotData
    }

    func sendHIDPress(page: UInt32, usage: UInt32) {}
    func sendTouch(phase: Int, x: Double, y: Double) {}
}

@MainActor
final class VPhoneClipboardSync {
    var adopted = false
    func adoptGuestClipboard() { adopted = true }
}

@MainActor
final class VPhoneVirtualMachineView: NSView {
    var recordingGraphicsDisplay: VZGraphicsDisplay? { nil }
    var clipboardSync: VPhoneClipboardSync? = VPhoneClipboardSync()
    var taps = 0
    func injectTap(pixelX: Double, pixelY: Double, screenWidth: Int, screenHeight: Int) { taps += 1 }
    func injectSwipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     screenWidth: Int, screenHeight: Int, durationMs: Int) {}
}

@MainActor
final class VPhoneVirtualMachine {
    var networkStatus: [String: Any] { [:] }
    func setNetworkLink(up: Bool) throws {}
}

@MainActor
enum VPhoneHostKeyEvents {
    static func press(_ keys: String, in view: VPhoneVirtualMachineView) async throws {}
}

@MainActor
final class VPhoneTestScreenRecorder: VPhoneScreenRecorder {
    let frame: CGImage
    var captures = 0
    var refusesCapture = false

    init(frame: CGImage) { self.frame = frame }

    override func captureStillImage(from view: NSView) async throws -> CGImage {
        captures += 1
        if refusesCapture { throw Failure.capture }
        return frame
    }

    enum Failure: Error { case capture }
}

@main
struct VPhoneHostAutomationServerTests {
    nonisolated static func exchange(path: String, line: String) throws -> String {
        let fd = try VPhoneUnixSocket.connect(to: path).get()
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let request = Data((line + "\n").utf8)
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !reply.contains(0x0A) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.EIO) }
            reply.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: reply, as: UTF8.self)
    }

    @MainActor static func request(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let reply = try await Task.detached { try exchange(path: path, line: line) }.value
        return try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    }

    static func image(_ data: Data, width: Int, height: Int, type: String) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        assert(CGImageSourceGetType(source) as String? == type)
        let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        assert(frame.width == width && frame.height == height)
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let path = directory.appendingPathComponent("host.sock").path
        let context = CGContext(data: nil, width: 1290, height: 2796, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1290, height: 2796))
        let frame = context.makeImage()!
        let recorder = VPhoneTestScreenRecorder(frame: frame)
        let guest = VPhoneGuestControl()
        let view = VPhoneVirtualMachineView(frame: CGRect(x: 0, y: 0, width: 215, height: 466))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let server = VPhoneHostAutomationServer(socketPath: path)
        server.start(captureView: view, screenRecorder: recorder, control: guest, screenWidth: 1290, screenHeight: 2796)
        defer { server.stop() }

        // Optional isolated endpoint for testing an installed Poke CLI.
        if CommandLine.arguments.contains("--serve") {
            print("READY \(path)")
            fflush(stdout)
            try await Task.sleep(for: .seconds(60))
            return
        }

        let launch = try await request(path, ["t": "app_launch", "bundle_id": "com.apple.Preferences",
                                               "url": "prefs:", "delay": 0])
        assert(launch["ok"] as? Bool == true && launch["pid"] as? Int == 123 && launch["result"] == nil)
        assert(guest.requests.last!.0 == "apps.launch" && guest.requests.last!.1["url"] as? String == "prefs:")
        image(Data(base64Encoded: launch["image"] as! String)!, width: 430, height: 932, type: "public.jpeg")

        let list = try await request(path, ["t": "app_list", "filter": "running", "screen": false])
        assert((list["apps"] as? [[String: Any]])?.first?["bundle_id"] as? String == "com.apple.Preferences")
        assert(guest.requests.last!.1["filter"] as? String == "running" && list["image"] == nil)
        _ = try await request(path, ["t": "app_list", "screen": false])
        assert(guest.requests.last!.1["filter"] as? String == "all")

        for (command, method) in [("app_terminate", "apps.terminate"), ("app_uninstall", "apps.uninstall")] {
            let reply = try await request(path, ["t": command, "bundle_id": "test.app", "screen": false])
            assert(reply["ok"] as? Bool == true && reply["image"] == nil && guest.requests.last!.0 == method)
            if command == "app_uninstall" { assert(guest.requests.last!.1["force"] as? Bool == true) }
        }
        let url = try await request(path, ["t": "open_url", "url": "https://example.com", "screen": false])
        assert(url["ok"] as? Bool == true && guest.requests.last!.0 == "apps.open_url")
        for command in ["clipboard_set", "type"] {
            let reply = try await request(path, ["t": command, "text": "", "screen": false])
            assert(reply["ok"] as? Bool == true && guest.requests.last!.0 == "clipboard.set")
            assert(guest.requests.last!.1["text"] as? String == "" && view.clipboardSync!.adopted)
        }
        let clipboard = try await request(path, ["t": "clipboard_get", "screen": false])
        assert(clipboard["text"] as? String == "clipboard")
        let install = try await request(path, ["t": "ipa_install", "path": "/tmp/test.ipa", "screen": false])
        assert(install["bundle_id"] as? String == "test.installed" && guest.installedURL?.path == "/tmp/test.ipa")

        // Bad parameters fail before reaching the guest.
        let previousRequests = guest.requests.count
        for command in ["app_launch", "app_terminate", "app_uninstall", "open_url", "clipboard_set", "ipa_install"] {
            let reply = try await request(path, ["t": command, "screen": false])
            assert(reply["ok"] as? Bool == false && reply["error"] != nil)
        }
        assert(guest.requests.count == previousRequests)

        // Explicit guest refusals retain both the old error string and RPC detail.
        guest.failure = VPhoneGuestControl.GuestRPCFailure(body: ["code": "not_installed", "message": "No such app", "errno": 2])
        for command in [["t": "app_launch", "bundle_id": "missing", "screen": false] as [String: Any],
                        ["t": "rpc", "method": "apps.launch", "params": ["bundle_id": "missing"]],
                        ["t": "clipboard_set", "text": "value", "screen": false]] {
            let reply = try await request(path, command)
            assert(reply["ok"] as? Bool == false && reply["error"] as? String == "No such app")
            assert((reply["guest_error"] as? [String: Any])?["errno"] as? Int == 2 && reply["image"] == nil)
        }
        guest.failure = nil
        let rpc = try await request(path, ["t": "rpc", "method": "apps.list"])
        assert(rpc["apps"] == nil && (rpc["result"] as? [String: Any])?["apps"] != nil && rpc["image"] == nil)

        // Exercise the production legacy reply parser as well as the host's
        // RPC error forwarding: neither legacy error form may become ok=true.
        for value: [String: Any] in [["t": "err", "msg": "No such app"],
                                     ["t": "app_launch", "ok": false, "error": "No such app", "code": "not_installed"]] {
            do {
                _ = try VPhoneLegacyGuestControl.decodeReply(JSONSerialization.data(withJSONObject: value))
                fatalError("Legacy refusal became success")
            } catch let failure as VPhoneGuestControl.GuestRPCFailure {
                assert(failure.message == "No such app")
                assert(failure.body["code"] as? String == (value["code"] as? String ?? "legacy_guest_error"))
            }
        }
        let legacy = try VPhoneLegacyGuestControl.decodeReply(Data(#"{"t":"app_list","apps":[]}"#.utf8))
        assert(legacy["ok"] as? Bool == true && legacy["apps"] != nil)

        // A windowed legacy guest needs no screenshot RPC, even disconnected.
        guest.isConnected = false
        let pngURL = directory.appendingPathComponent("full.png")
        let captures = recorder.captures
        let shot = try await request(path, ["t": "screenshot", "path": pngURL.path, "screen": false])
        assert(shot["ok"] as? Bool == true && shot["path"] as? String == pngURL.path)
        assert(shot["width"] as? Int == 1290 && shot["height"] as? Int == 2796 && shot["format"] as? String == "png")
        assert(recorder.captures == captures + 1 && guest.screenshotRequests == 0)
        image(try Data(contentsOf: pngURL), width: 1290, height: 2796, type: "public.png")
        image(Data(base64Encoded: shot["image"] as! String)!, width: 430, height: 932, type: "public.jpeg")
        let badSave = try await request(path, ["t": "screenshot", "path": directory.appendingPathComponent("absent/shot.png").path])
        assert(badSave["ok"] as? Bool == false && badSave["path"] == nil)
        recorder.refusesCapture = true
        let badCapture = try await request(path, ["t": "screenshot", "path": pngURL.path])
        assert(badCapture["ok"] as? Bool == false && guest.screenshotRequests == 0)
        recorder.refusesCapture = false
        let disconnected = try await request(path, ["t": "app_list", "screen": false])
        assert(disconnected["ok"] as? Bool == false && disconnected["error"] as? String == "guest not connected")
        guest.isConnected = true
        let tap = try await request(path, ["t": "tap", "x": 645, "y": 1398, "delay": 0])
        assert(tap["ok"] as? Bool == true && view.taps == 1)
        image(Data(base64Encoded: tap["image"] as! String)!, width: 430, height: 932, type: "public.jpeg")

        // A headless modern guest uses its full native JPEG. A legacy guest
        // must return an explicit refusal instead of inventing a saved file.
        server.stop()
        server.start(captureView: nil, screenRecorder: recorder, control: guest, screenWidth: 1290, screenHeight: 2796)
        let unsupported = try await request(path, ["t": "screenshot", "path": pngURL.path])
        assert(unsupported["ok"] as? Bool == false && unsupported["path"] == nil && unsupported["image"] == nil)
        assert((unsupported["error"] as? String)?.contains("screen.screenshot") == true)
        let jpegURL = try recorder.saveScreenshot(image: frame, to: directory.appendingPathComponent("full.jpg"))
        guest.screenshotData = try Data(contentsOf: jpegURL)
        image(guest.screenshotData!, width: 1290, height: 2796, type: "public.jpeg")
        let headless = try await request(path, ["t": "screenshot", "path": pngURL.path])
        assert(headless["ok"] as? Bool == true)
        image(try Data(contentsOf: pngURL), width: 1290, height: 2796, type: "public.png")
        guest.screenshotData = Data("invalid".utf8)
        let invalid = try await request(path, ["t": "screenshot", "path": pngURL.path])
        assert(invalid["ok"] as? Bool == false && invalid["path"] == nil)
        print("Host automation tests passed: socket aliases, response shape, legacy refusals, full PNG/JPEG, compact frames and headless fallback")
    }
}
