import Foundation

struct VPhoneSSHCommandResult {
    let exitStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum VPhoneSSHError: Error, CustomStringConvertible {
    case notConnected
    case commandFailed(String)

    var description: String {
        switch self {
        case .notConnected:
            return "SSH client is not connected"
        case let .commandFailed(message):
            return message
        }
    }
}

final class VPhoneSSHClient: @unchecked Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String

    private var connected = false
    private var controlPath: URL?

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    func connect() throws {
        if connected { return }
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        let socketPath = URL(fileURLWithPath: "/tmp/vssh.\(token).sock")
        do {
            let result = try runProcess(
                executable: "/usr/bin/ssh",
                arguments: masterArguments(controlPath: socketPath),
                stdin: nil
            )
            guard result.exitStatus == 0 else {
                throw VPhoneSSHError.commandFailed(result.standardErrorString)
            }
            controlPath = socketPath
            connected = true
        } catch {
            try? FileManager.default.removeItem(at: socketPath)
            throw error
        }
    }

    func shutdown() throws {
        if let controlPath {
            _ = try? runProcess(
                executable: "/usr/bin/ssh",
                arguments: controlArguments(controlPath: controlPath) + ["-O", "exit", "\(username)@\(host)"],
                stdin: nil
            )
        }
        if let controlPath {
            try? FileManager.default.removeItem(at: controlPath)
        }
        controlPath = nil
        connected = false
    }

    func execute(_ command: String, stdin: Data? = nil, requireSuccess: Bool = true) throws -> VPhoneSSHCommandResult {
        guard connected else {
            throw VPhoneSSHError.notConnected
        }

        let result = try runSSH(command: command, stdin: stdin)
        if requireSuccess, result.exitStatus != 0 {
            let stderr = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VPhoneSSHError.commandFailed(
                stderr.isEmpty
                    ? "SSH command failed with status \(result.exitStatus): \(command)"
                    : "SSH command failed with status \(result.exitStatus): \(command)\n\(stderr)"
            )
        }
        return result
    }

    func uploadFile(localURL: URL, remotePath: String) throws {
        let resolvedRemotePath = try resolveRemoteUploadPath(remotePath, localName: localURL.lastPathComponent)
        _ = try execute("/bin/cat > \(shellQuote(resolvedRemotePath))", stdin: try Data(contentsOf: localURL))
        try applyPOSIXPermissionsIfPresent(for: localURL, remotePath: resolvedRemotePath)
    }

    func uploadData(_ data: Data, remotePath: String) throws {
        _ = try execute("/bin/cat > \(shellQuote(remotePath))", stdin: data)
    }

    func downloadFile(remotePath: String, localURL: URL) throws {
        let result = try execute("/bin/cat \(shellQuote(remotePath))")
        try result.standardOutput.write(to: localURL)
    }

    func uploadDirectory(localURL: URL, remotePath: String) throws {
        let tarData = try VPhoneArchive.createTarArchive(from: localURL)
        _ = try execute(
            "/bin/rm -rf \(shellQuote(remotePath)) && /bin/mkdir -p \(shellQuote(remotePath)) && /usr/bin/tar -xf - -C \(shellQuote(remotePath))",
            stdin: tarData
        )
        try applyPOSIXPermissionsIfPresent(for: localURL, remotePath: remotePath)
    }

    func uploadDirectoryContents(localURL: URL, remotePath: String) throws {
        try createRemoteDirectory(remotePath)
        let tarData = try VPhoneArchive.createTarArchive(from: localURL)
        _ = try execute("/usr/bin/tar -xf - -C \(shellQuote(remotePath))", stdin: tarData)
    }

    static func probe(host: String, port: Int, username: String, password: String) -> Bool {
        do {
            let client = VPhoneSSHClient(host: host, port: port, username: username, password: password)
            defer { try? client.shutdown() }
            try client.connect()
            let result = try client.execute("echo ready", requireSuccess: false)
            return result.exitStatus == 0 && result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "ready"
        } catch {
            if ProcessInfo.processInfo.environment["VPHONE_SSH_DEBUG"] == "1" {
                let message = "[ssh probe] \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            return false
        }
    }

    private func runSSH(command: String, stdin: Data?) throws -> VPhoneSSHCommandResult {
        let result = try runProcess(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(command: command),
            stdin: stdin
        )
        return VPhoneSSHCommandResult(
            exitStatus: result.exitStatus,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }

    private func sshArguments(command: String) -> [String] {
        var arguments = sshBaseArguments()
        if let controlPath {
            arguments.append(contentsOf: controlArguments(controlPath: controlPath))
        }
        arguments.append(contentsOf: [
            "-p", "\(port)",
            "\(username)@\(host)",
            command,
        ])
        return arguments
    }

    private func masterArguments(controlPath: URL) -> [String] {
        var arguments = sshBaseArguments()
        arguments.append(contentsOf: [
            "-M",
            "-S", controlPath.path,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=yes",
            "-p", "\(port)",
            "-f",
            "-N",
            "\(username)@\(host)",
        ])
        return arguments
    }

    private func sshBaseArguments() -> [String] {
        [
            "-F", "/dev/null",
            "-T",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=5",
        ]
    }

    private func controlArguments(controlPath: URL) -> [String] {
        ["-S", controlPath.path, "-o", "ControlMaster=no"]
    }

    private func runProcess(executable: String, arguments: [String], stdin: Data?) throws -> VPhoneSSHCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in VPhoneHost.sshAskpassEnvironment(password: password) {
            if let value {
                environment[key] = value
            } else {
                environment.removeValue(forKey: key)
            }
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdin, !stdin.isEmpty {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin)
            try stdinPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return VPhoneSSHCommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func uploadItem(localURL: URL, remotePath: String) throws {
        let fileManager = FileManager.default
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])

        if values.isDirectory == true {
            try createRemoteDirectory(remotePath)
            try applyPOSIXPermissionsIfPresent(for: localURL, remotePath: remotePath)
            let children = try fileManager.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try uploadItem(localURL: child, remotePath: remotePath + "/" + child.lastPathComponent)
            }
            return
        }

        if values.isSymbolicLink == true {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: localURL.path)
            let parent = (remotePath as NSString).deletingLastPathComponent
            try createRemoteDirectory(parent)
            _ = try execute(
                "/bin/rm -rf \(shellQuote(remotePath)) && /bin/ln -s \(shellQuote(destination)) \(shellQuote(remotePath))"
            )
            return
        }

        guard values.isRegularFile == true else {
            return
        }
        let resolvedRemotePath = try resolveRemoteUploadPath(remotePath, localName: localURL.lastPathComponent)
        let parent = (resolvedRemotePath as NSString).deletingLastPathComponent
        try createRemoteDirectory(parent)
        try uploadFile(localURL: localURL, remotePath: resolvedRemotePath)
    }

    private func createRemoteDirectory(_ path: String) throws {
        guard !path.isEmpty, path != "." else { return }
        _ = try execute("/bin/mkdir -p \(shellQuote(path))")
    }

    private func applyPOSIXPermissionsIfPresent(for localURL: URL, remotePath: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            return
        }
        let mode = String(permissions.intValue, radix: 8)
        _ = try execute("/bin/chmod \(mode) \(shellQuote(remotePath))")
    }

    private func resolveRemoteUploadPath(_ remotePath: String, localName: String) throws -> String {
        if remotePath.hasSuffix("/") {
            return (remotePath as NSString).appendingPathComponent(localName)
        }

        let result = try execute("test -d \(shellQuote(remotePath))", requireSuccess: false)
        if result.exitStatus == 0 {
            return (remotePath as NSString).appendingPathComponent(localName)
        }
        return remotePath
    }
}
