import Foundation
import Observation

/// One downloadable iPhone firmware, parsed from `fw_prepare.sh --list`.
struct VPhoneFirmware: Identifiable, Hashable, Sendable {
    let version: String
    let build: String
    let status: String // "Supported" | "Not Tested" | "Unsupported"
    /// Host labels (e.g. "Mac16,11 26.2") this build was tested on, from
    /// README's "## Tested Environments" table. Empty when not listed there.
    var testedHosts: [String] = []
    /// One of `testedHosts` matches this Mac's `hw.model`.
    var testedOnThisMac: Bool = false
    /// The base Restore IPSW is already cached under `ipsws/` (create won't
    /// re-download ~10 GB).
    var ipswCached: Bool = false

    var id: String { build }
    var label: String { "\(version) (\(build))" }
    var isSupported: Bool { status.lowercased() == "supported" }

    /// Honest one-liner for the picker. "Supported" only ever meant "listed in
    /// the tested matrix" — and the matrix is per host model. Surfacing *which*
    /// host stops a green badge earned on another Mac from reading as a
    /// guarantee on this one. Only an actual boot+connect proves a build works.
    var supportSummary: String {
        guard isSupported else { return status }
        if testedOnThisMac { return "Supported · this Mac" }
        if let host = testedHosts.first { return "Supported · \(host)" }
        return "Supported"
    }
}

/// Fetches and holds the list of downloadable IPSWs for the create wizard's
/// version picker, by driving `make fw_prepare LIST_FIRMWARES=1` and parsing its
/// VERSION/BUILD/STATUS table.
@Observable
@MainActor
final class VPhoneFirmwareCatalog {
    let repoRoot: URL
    let device: String

    var firmwares: [VPhoneFirmware] = []
    var isLoading = false
    var error: String?

    init(repoRoot: URL, device: String = "iPhone17,3") {
        self.repoRoot = repoRoot
        self.device = device
    }

    func load() async {
        isLoading = true
        error = nil
        let root = repoRoot
        let dev = device
        let result = await Task.detached { Self.fetch(repoRoot: root, device: dev) }.value
        switch result {
        case let .success(list):
            firmwares = list
            if list.isEmpty { error = "No firmwares returned. Check network / the `ipsw` tool." }
        case let .failure(message):
            error = message
        }
        isLoading = false
    }

    private enum FetchResult: Sendable {
        case success([VPhoneFirmware])
        case failure(String)
    }

    private nonisolated static func fetch(repoRoot: URL, device: String) -> FetchResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["fw_prepare", "LIST_FIRMWARES=1", "IPHONE_DEVICE=\(device)"]
        p.currentDirectoryURL = repoRoot
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
        } catch {
            return .failure("Could not run make fw_prepare: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("Unreadable output from fw_prepare")
        }
        guard p.terminationStatus == 0 else {
            return .failure(text.split(separator: "\n").suffix(4).joined(separator: "\n"))
        }
        return .success(enrich(parse(text), repoRoot: repoRoot, device: device))
    }

    /// Annotate each build with where it was tested (README matrix), whether
    /// that includes this Mac, and whether its IPSW is already cached.
    nonisolated static func enrich(_ base: [VPhoneFirmware], repoRoot: URL, device: String) -> [VPhoneFirmware] {
        let hostsByBuild = testedHostsByBuild(repoRoot: repoRoot, device: device)
        let model = hostModel()
        return base.map { fw in
            var f = fw
            f.testedHosts = hostsByBuild[fw.build] ?? []
            f.testedOnThisMac = !model.isEmpty
                && f.testedHosts.contains { $0 == model || $0.hasPrefix(model + " ") }
            let ipsw = repoRoot.appendingPathComponent("ipsws/\(device)_\(fw.version)_\(fw.build)_Restore.ipsw")
            f.ipswCached = FileManager.default.fileExists(atPath: ipsw.path)
            return f
        }
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

    /// Parse rows like `26.5         23F77      Supported`, skipping the header
    /// and the "Status:" legend line.
    nonisolated static func parse(_ text: String) -> [VPhoneFirmware] {
        var result: [VPhoneFirmware] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("VERSION") || line.hasPrefix("Status:") { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { continue }
            let version = cols[0]
            // A version row starts with a dotted number; skip prose lines.
            guard version.first?.isNumber == true, version.contains(".") else { continue }
            let build = cols[1]
            let status = cols.count >= 3 ? cols[2...].joined(separator: " ") : "Unknown"
            result.append(VPhoneFirmware(version: version, build: build, status: status))
        }
        return result
    }
}
