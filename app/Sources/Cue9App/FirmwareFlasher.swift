import CryptoKit
import Foundation

@MainActor
final class FirmwareFlasher: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published var isFlashing = false
    @Published var log = ""
    @Published var status: String?
    @Published var firmwareHash = ""

    init() {
        refreshPorts()
        firmwareHash = Self.hashFirmware()
    }

    func refreshPorts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = names.filter { $0.hasPrefix("cu.usbmodem") }.map { "/dev/\($0)" }.sorted()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first ?? ""
        }
    }

    func waitForPortFree(_ port: String, timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !Self.portIsHeld(port) { return true }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return !Self.portIsHeld(port)
    }

    @discardableResult
    func flash(config: Data? = nil) async -> Bool {
        guard !isFlashing else { return false }
        guard !selectedPort.isEmpty else {
            status = "Select a mote USB port first."
            return false
        }
        guard let firmware = Bundle.module.url(forResource: "firmware", withExtension: "bin")
                ?? Self.repoFirmware() else {
            status = "Firmware image is missing from the app."
            return false
        }
        guard let tool = Self.findEsptool() else {
            status = "esptool was not found. Install esptool or keep the ESP-IDF toolchain available."
            return false
        }

        guard await waitForPortFree(selectedPort) else {
            status = "The USB port is still held by the DSH bridge. Release it and try again."
            return false
        }

        var files = ["0x0", firmware.path]
        var configURL: URL?
        if let config {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cue9cfg-\(UUID().uuidString).bin")
            do {
                try config.write(to: url)
            } catch {
                status = "Could not write the config image."
                return false
            }
            files += ["0x310000", url.path]
            configURL = url
        }
        defer { if let configURL { try? FileManager.default.removeItem(at: configURL) } }

        isFlashing = true
        log = ""
        status = config == nil ? "Flashing the mote…" : "Flashing the mote and its Wi-Fi config…"
        append("firmware \(firmware.path)\n")
        append("port \(selectedPort)\n")
        append("tool \(tool.display)\n")
        if configURL != nil { append("config 0x310000\n") }

        var arguments = tool.prefix
        arguments += ["--chip", "esp32s3", "-p", selectedPort, "-b", "460800",
                      "--before", "default_reset", "--after", "hard_reset",
                      "write_flash"] + files

        append("$ \(tool.executable) \(arguments.joined(separator: " "))\n")
        let result = await Self.run(executable: tool.executable, arguments: arguments)
        append(result.output)
        if result.code == 0 {
            status = "Flashed successfully."
        } else {
            status = "Flash failed with exit code \(result.code)."
        }
        isFlashing = false
        return result.code == 0
    }

    func append(_ text: String) {
        log += text.hasSuffix("\n") ? text : text + "\n"
    }

    private struct Tool {
        let executable: String
        let prefix: [String]
        let display: String
    }

    private static func findEsptool() -> Tool? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/esptool.py",
            "\(home)/Library/Python/3.11/bin/esptool.py",
            "\(home)/esp/esp-idf-v5.5.1/components/esptool_py/esptool/esptool.py",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if path.hasSuffix(".py") {
                let python = FileManager.default.fileExists(atPath: "/usr/local/bin/python3")
                    ? "/usr/local/bin/python3" : "/usr/bin/env"
                if python == "/usr/bin/env" {
                    return Tool(executable: "/usr/bin/env", prefix: ["python3", path], display: "python3 \(path)")
                }
                return Tool(executable: python, prefix: [path], display: "\(python) \(path)")
            }
            return Tool(executable: path, prefix: [], display: path)
        }
        return nil
    }

    private static func portIsHeld(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return !data.isEmpty
        } catch {
            return false
        }
    }

    private static func repoFirmware() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("firmware/build/cue9-full.bin")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func hashFirmware() -> String {
        guard let url = Bundle.module.url(forResource: "firmware", withExtension: "bin")
                ?? repoFirmware(),
              let data = try? Data(contentsOf: url) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct RunResult {
        let code: Int32
        let output: String
    }

    private nonisolated static func run(executable: String, arguments: [String]) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: RunResult(
                        code: process.terminationStatus,
                        output: String(data: data, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(returning: RunResult(code: -1, output: error.localizedDescription + "\n"))
                }
            }
        }
    }
}
