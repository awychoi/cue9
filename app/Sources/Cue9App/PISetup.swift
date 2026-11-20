import Foundation

/// Installs the Pi half over SSH. The password is used once through an askpass
/// helper and never stored; the mote's key lands in ~/.dsh/cue9/pi.json (0600).
struct PISetup {
    let host: String
    let password: String?

    enum SetupError: LocalizedError {
        case missingBundle
        case key
        case ssh(String)
        case install(String)
        case summary(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle:
                return "The Pi setup files are missing from the app."
            case .key:
                return "Could not create the cue9 SSH key."
            case .ssh(let log):
                return "Could not reach the Pi over SSH.\n\(PISetup.tail(log))"
            case .install(let log):
                return "The Pi setup failed.\n\(PISetup.tail(log))"
            case .summary(let log):
                return "The Pi answered, but its setup summary was not readable.\n\(PISetup.tail(log))"
            }
        }
    }

    /// The app's own key, restricted on the Pi to `cue9-attach`.
    static var runKeyPath: String {
        CuePaths.support.appendingPathComponent("ssh/id_ed25519").path
    }

    func install() async throws -> (summary: PiSummary, log: String, runKey: String) {
        guard let resources = Bundle.main.resourceURL else {
            throw SetupError.missingBundle
        }
        let bundle = resources.appendingPathComponent("cue9-pi", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw SetupError.missingBundle
        }

        let publicKey = try ensureRunKey()
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue9-pi-stage-\(UUID().uuidString)", isDirectory: true)
        let staged = stagingRoot.appendingPathComponent("cue9-pi", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle, to: staged)
        try publicKey.write(
            to: staged.appendingPathComponent("run.pub"),
            atomically: false,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let askpass: Askpass?
        let environment: [String: String]
        if let password, !password.isEmpty {
            let helper = try Askpass(password: password)
            askpass = helper
            environment = helper.environment
        } else {
            askpass = nil
            environment = ProcessInfo.processInfo.environment
        }
        defer { askpass?.cleanup() }

        let options = [
            "-o", "BatchMode=\(password == nil || password?.isEmpty == true ? "yes" : "no")",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
        ]

        let probe = try await run("/usr/bin/ssh", options + ["-T", host, "true"], environment: environment)
        guard probe.code == 0 else { throw SetupError.ssh(probe.output) }

        _ = try await run("/usr/bin/ssh", options + ["-T", host, "rm -rf /tmp/cue9-pi"], environment: environment)
        let copy = try await run(
            "/usr/bin/scp",
            ["-r"] + options + [staged.path, "\(host):/tmp/"],
            environment: environment
        )
        guard copy.code == 0 else { throw SetupError.install(copy.output) }

        let install = try await run(
            "/usr/bin/ssh",
            options + ["-T", host, "bash /tmp/cue9-pi/cue9_pi_setup.sh --run-key-file /tmp/cue9-pi/run.pub"],
            environment: environment
        )
        guard install.code == 0 else { throw SetupError.install(install.output) }

        let jsonLine = install.output
            .split(separator: "\n")
            .reversed()
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let jsonLine,
              let data = jsonLine.data(using: .utf8),
              let summary = try? JSONDecoder().decode(PiSummary.self, from: data) else {
            throw SetupError.summary(install.output)
        }
        try MoteProvisioning.saveSummary(data)
        return (summary, install.output, Self.runKeyPath)
    }

    private func ensureRunKey() throws -> String {
        let key = URL(fileURLWithPath: Self.runKeyPath)
        let directory = key.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        if !FileManager.default.fileExists(atPath: key.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-t", "ed25519", "-N", "", "-C", "cue9-app", "-f", key.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                throw SetupError.key
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SetupError.key }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: key.path
        )

        let publicPath = key.path + ".pub"
        guard let data = FileManager.default.contents(atPath: publicPath),
              let text = String(data: data, encoding: .utf8) else {
            throw SetupError.key
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> (code: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    private static func tail(_ log: String, limit: Int = 1200) -> String {
        let text = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }
}

/// A 0600 password file plus a 0700 askpass helper, deleted after the install.
private final class Askpass {
    let directory: URL
    let environment: [String: String]

    init(password: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue9-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let passwordFile = directory.appendingPathComponent("password")
        try password.write(to: passwordFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordFile.path
        )

        let helper = directory.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\ncat \"$CUE9_ASKPASS_FILE\"\n"
            .write(to: helper, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        env["CUE9_ASKPASS_FILE"] = passwordFile.path
        environment = env
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
