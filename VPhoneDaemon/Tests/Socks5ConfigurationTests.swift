import Foundation
import VphonedNative

// The API's error boundary is the only guest-dependent type in GuestSocks5.
enum GuestAPIError: Error { case invalidRequest(String), operationFailed(String) }
enum GuestAPI {}

@main
struct Socks5ConfigurationTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { _ = vp_socks5_set_port(0); try? FileManager.default.removeItem(at: directory) }
        let save = directory.appendingPathComponent("proxy.plist")
        let proxy = GuestSocks5(saveURL: save)
        precondition(proxy.describe()["enabled"] as? Bool == false)
        for invalid: Any in [true, -1, 1023, 65536, 1080.5, "1080"] {
            do {
                _ = try proxy.configure(["port": invalid])
                fatalError("Accepted invalid port \(invalid)")
            } catch GuestAPIError.invalidRequest { }
        }
        var port = 0
        for _ in 0 ..< 100 {
            let candidate = Int.random(in: 40000 ... 60000)
            if let result = try? proxy.configure(["port": candidate]) {
                port = result["port"] as? Int ?? 0
                break
            }
        }
        precondition(port != 0)
        precondition(proxy.describe()["saved_port"] as? Int == port)
        _ = vp_socks5_set_port(0) // stands in for daemon exit, in this process only
        let restored = GuestSocks5(saveURL: save)
        restored.restoreOnStartup()
        precondition(restored.describe()["port"] as? Int == port)
        precondition(restored.describe()["saved_port"] as? Int == port)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let cannotSave = GuestSocks5(saveURL: blocker.appendingPathComponent("proxy.plist"))
        do {
            _ = try cannotSave.configure(["port": 0])
            fatalError("Accepted unwritable configuration")
        } catch GuestAPIError.operationFailed { }
        precondition(vp_socks5_port() == port) // runtime was rolled back
        _ = try restored.configure(["port": 0])
        let disabled = GuestSocks5(saveURL: save)
        disabled.restoreOnStartup()
        precondition(disabled.describe()["enabled"] as? Bool == false)
        precondition(disabled.describe()["saved_port"] as? Int == 0)
        print("PASS SOCKS5 configuration: input validation, saved enable/disable, daemon restart restoration, persistence failure rollback")
    }
}
