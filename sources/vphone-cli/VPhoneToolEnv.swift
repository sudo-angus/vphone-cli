import Foundation

/// Environment for child processes the manager spawns (make, the setup/firmware
/// scripts, the boot binary). A GUI-launched app does NOT inherit the shell
/// PATH: Finder / Spotlight / Dock start it from launchd with a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so the Homebrew tools the pipeline needs —
/// `ipsw`, `aria2`, `ldid`, `gnu-tar`, … — aren't found and `make fw_prepare`
/// dies with "'ipsw' not found". (`make manage` from a terminal never hits this
/// because it inherits the shell PATH.) Prepend the usual Homebrew prefixes and
/// the project-local tool dirs so spawned tools resolve however the app launched.
enum VPhoneToolEnv {
    static func environment(repoRoot: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prepend = [
            repoRoot.appendingPathComponent(".tools/bin").path,
            repoRoot.appendingPathComponent(".venv/bin").path,
            "/opt/homebrew/bin", "/opt/homebrew/sbin", // Apple Silicon Homebrew
            "/usr/local/bin", // Intel Homebrew / misc
        ]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (prepend + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}
