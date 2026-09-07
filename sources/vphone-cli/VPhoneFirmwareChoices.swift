import Foundation
import Observation
import VPhoneCore

/// One downloadable iPhone/cloudOS pairing from VPhoneCore's catalog, annotated
/// with what the create wizard shows next to it: where the project tested the
/// build, whether that includes this Mac, and whether the IPSW is already on
/// disk.
struct VPhoneFirmware: Identifiable, Hashable, Sendable {
    /// Friendly name from the catalog, e.g. "iOS 26.5" or "iOS 27 beta 8".
    let iosName: String
    /// Dotted version parsed from the IPSW file name, e.g. "26.5".
    let version: String
    /// Build id parsed from the IPSW file name, e.g. "23F77".
    let build: String
    let iosURL: String
    /// The cloudOS image the catalog recommends for this build.
    let cloudosName: String
    let cloudosURL: String
    /// Host labels (e.g. "Mac16,11 26.2") this build was tested on, from
    /// README's "## Tested Environments" table. Empty when not listed there.
    var testedHosts: [String] = []
    /// One of `testedHosts` matches this Mac's `hw.model`.
    var testedOnThisMac = false
    /// The base Restore IPSW is already cached (create won't re-download ~10 GB).
    var ipswCached = false

    var id: String { build }
    var label: String { "\(iosName) (\(build)) → \(cloudosName)" }
    var isSupported: Bool { !testedHosts.isEmpty }

    /// Honest one-liner for the picker. "Tested" only ever means "listed in the
    /// project's tested matrix", and the matrix is per host model, so surface
    /// *which* host: a badge earned on another Mac must not read as a guarantee
    /// on this one. Only an actual boot + connect proves a build works.
    var supportSummary: String {
        guard isSupported else { return "Untested" }
        if testedOnThisMac { return "Tested · this Mac" }
        if let host = testedHosts.first { return "Tested · \(host)" }
        return "Tested"
    }
}

/// The create wizard's version picker source: VPhoneCore's static catalog of
/// iPhone ↔ cloudOS pairings (the same list `vphone-cli fw catalog` prints),
/// enriched off the main thread with README's tested matrix and the state of
/// the local IPSW caches.
@Observable
@MainActor
final class VPhoneFirmwareChoices {
    let repoRoot: URL

    var firmwares: [VPhoneFirmware] = []
    var isLoading = false
    var error: String?

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    func load() async {
        isLoading = true
        error = nil
        let root = repoRoot
        firmwares = await Task.detached { Self.build(repoRoot: root) }.value
        if firmwares.isEmpty { error = "The firmware catalog is empty." }
        isLoading = false
    }

    nonisolated static func build(repoRoot: URL) -> [VPhoneFirmware] {
        let device = VPhoneFirmwareCatalog.device
        let hostsByBuild = testedHostsByBuild(repoRoot: repoRoot, device: device)
        let model = hostModel()
        // `vm create` downloads into the per-user cache; the make flow used the
        // clone's ipsws/. Either counts as "already here".
        let caches = [
            VPhoneResources.userDataRoot().appendingPathComponent("ipsws"),
            repoRoot.appendingPathComponent("ipsws"),
        ]
        return VPhoneFirmwareCatalog.pairings.compactMap { pairing in
            guard let file = URL(string: pairing.iosURL)?.lastPathComponent,
                  let parsed = parseVersionBuild(fileName: file)
            else { return nil }
            var fw = VPhoneFirmware(
                iosName: pairing.iosName,
                version: parsed.version,
                build: parsed.build,
                iosURL: pairing.iosURL,
                cloudosName: pairing.cloudosName,
                cloudosURL: pairing.cloudosURL
            )
            fw.testedHosts = hostsByBuild[fw.build] ?? []
            fw.testedOnThisMac = !model.isEmpty
                && fw.testedHosts.contains { $0 == model || $0.hasPrefix(model + " ") }
            fw.ipswCached = caches.contains { isCached(device: device, version: fw.version, build: fw.build, in: $0) }
            return fw
        }
    }

    /// `iPhone17,3_26.5_23F77_Restore.ipsw` → ("26.5", "23F77").
    nonisolated static func parseVersionBuild(fileName: String) -> (version: String, build: String)? {
        let parts = fileName.split(separator: "_")
        guard parts.count >= 4 else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// fw_prepare keeps the downloaded IPSW under its original file name, so a
    /// cached build starts with `<device>_<version>_<build>`.
    nonisolated private static func isCached(device: String, version: String, build: String, in dir: URL) -> Bool {
        let prefix = "\(device)_\(version)_\(build)"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.contains { $0.hasPrefix(prefix) }
    }

    /// `build → [host label]` from README's "## Tested Environments" table.
    nonisolated static func testedHostsByBuild(repoRoot: URL, device: String) -> [String: [String]] {
        guard let text = try? String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        else { return [:] }
        let suffix = String(device.dropFirst("iPhone".count)) // "iPhone17,3" → "17,3"
        var map: [String: [String]] = [:]
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## Tested Environments") { inSection = true; continue }
            if inSection, line.hasPrefix("## ") { break }
            guard inSection else { continue }

            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let host = cells.first, !host.isEmpty, host != "Host", !host.hasPrefix("---")
            else { continue }
            for token in backtickTokens(in: line) where token.hasPrefix(suffix + "_") {
                let rest = token.dropFirst(suffix.count + 1) // "26.5_23F77"
                guard let us = rest.lastIndex(of: "_") else { continue }
                let build = String(rest[rest.index(after: us)...])
                map[build, default: []].append(host)
            }
        }
        return map
    }

    private nonisolated static func backtickTokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current: String?
        for ch in line {
            if ch == "`" {
                if let c = current { tokens.append(c); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return tokens
    }

    /// This Mac's model identifier (e.g. "Mac14,5"), matching the README column.
    private nonisolated static func hostModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
