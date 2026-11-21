import Foundation

/// What the clock and weather pages are set to. The Pi is the owner; the app
/// edits it through the same restricted SSH key the plugin uses for the bridge.
struct AmbientSettings: Codable, Equatable {
    var timezone: String = ""
    var city: String = ""
    var lat: Double?
    var lon: Double?
    var units: String = "fahrenheit"
    var clock: Int = 12

    /// First-run guess: this Mac's zone and formats. Only used until the Pi
    /// answers with its real settings.
    static func forThisMac() -> AmbientSettings {
        var settings = AmbientSettings()
        settings.timezone = TimeZone.current.identifier
        settings.units = Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius"
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        settings.clock = pattern.contains("a") ? 12 : 24
        return settings
    }

    /// Last settings the Pi confirmed, so the card still shows something
    /// useful when the Pi is briefly unreachable.
    static func cached() -> AmbientSettings? {
        guard let data = UserDefaults.standard.data(forKey: "ambientSettings") else { return nil }
        return try? JSONDecoder().decode(AmbientSettings.self, from: data)
    }

    func cache() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "ambientSettings")
    }

    static func from(_ snapshot: AmbientSnapshot) -> AmbientSettings {
        var settings = AmbientSettings.forThisMac()
        settings.timezone = snapshot.timezone ?? ""
        settings.city = snapshot.city ?? ""
        settings.lat = snapshot.lat
        settings.lon = snapshot.lon
        if let units = snapshot.unitsEffective {
            settings.units = units == "celsius" ? "celsius" : "fahrenheit"
        }
        if let clock = snapshot.clock, clock == 24 || clock == 12 {
            settings.clock = clock
        }
        return settings
    }

    var clockLabel: String { clock == 24 ? "24-hour" : "12-hour" }
    var unitsLabel: String { units == "celsius" ? "°C" : "°F" }
}

struct AmbientSnapshot: Codable, Equatable {
    var enabled: Bool?
    var timezone: String?
    var piZone: String?
    var city: String?
    var lat: Double?
    var lon: Double?
    var units: String?
    var unitsEffective: String?
    var clock: Int?

    enum CodingKeys: String, CodingKey {
        case enabled, timezone, city, lat, lon, units, clock
        case piZone = "pi_zone"
        case unitsEffective = "units_effective"
    }
}

struct GeoCity: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
    let timezone: String?

    var place: String {
        [admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum AmbientError: LocalizedError {
    case noTarget
    case noKey
    case ssh(String)
    case timedOut
    case badReply(String)
    case rejected(String)
    case geo(String)

    var errorDescription: String? {
        switch self {
        case .noTarget:
            return "No Pi is configured. Set up the Pi first."
        case .noKey:
            return "The cue9 SSH key is missing. Set up the Pi first."
        case .ssh(let detail):
            return "Could not reach the Pi.\n\(detail)"
        case .timedOut:
            return "The Pi did not answer in time."
        case .badReply(let detail):
            return "The Pi sent something unexpected.\n\(detail)"
        case .rejected(let detail):
            return detail
        case .geo(let detail):
            return "Could not look up that city.\n\(detail)"
        }
    }
}

/// Reads and writes the Pi's ambient block over the same forced-command key the
/// plugin uses. The service sends its status line on connect, and answers an
/// `AMBIENT <json>` line with an `ambient` acknowledgement.
struct AmbientPiClient {
    let target: String
    let keyPath: String

    func fetch() async throws -> AmbientSnapshot {
        try await run(command: nil)
    }

    func save(_ settings: AmbientSettings) async throws -> AmbientSnapshot {
        var payload: [String: Any] = [
            "timezone": settings.timezone,
            "city": settings.city,
            "units": settings.units,
            "clock": settings.clock,
        ]
        payload["lat"] = settings.lat ?? NSNull()
        payload["lon"] = settings.lon ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw AmbientError.badReply("Could not encode the settings.")
        }
        return try await run(command: "AMBIENT " + json)
    }

    private func run(command: String?) async throws -> AmbientSnapshot {
        guard target.contains("@") else { throw AmbientError.noTarget }
        guard FileManager.default.fileExists(atPath: keyPath) else { throw AmbientError.noKey }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.runBlocking(command: command))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlocking(command: String?) throws -> AmbientSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-F", "/dev/null",
            "-i", keyPath,
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            target,
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AmbientError.ssh(error.localizedDescription)
        }

        if let command {
            do {
                try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            } catch {
                process.terminate()
                throw AmbientError.ssh("Could not send the settings.")
            }
        }

        let deadline = DispatchTime.now() + 10
        DispatchQueue.global().asyncAfter(deadline: deadline) { [process] in
            if process.isRunning { process.terminate() }
        }

        var buffer = Data()
        var snapshot: AmbientSnapshot?
        var rejection: String?
        var sawStatus = false
        var closed = false

        while !closed {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                closed = true
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                      let object = raw as? [String: Any],
                      let type = object["type"] as? String
                else { continue }

                if type == "status" {
                    sawStatus = true
                    if command == nil, let ambient = object["ambient"] {
                        snapshot = decodeSnapshot(ambient)
                        closed = true
                        break
                    }
                } else if type == "ambient", command != nil {
                    let ok = object["ok"] as? Bool ?? false
                    if ok, let ambient = object["ambient"] {
                        snapshot = decodeSnapshot(ambient)
                    } else {
                        rejection = object["error"] as? String ?? "The Pi rejected the settings."
                    }
                    closed = true
                    break
                }
            }
        }

        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        var detail = ""
        if let data = try? errors.fileHandleForReading.readToEnd() {
            detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let rejection { throw AmbientError.rejected(rejection) }
        if let snapshot { return snapshot }
        if !detail.isEmpty { throw AmbientError.ssh(detail) }
        if sawStatus, command == nil {
            throw AmbientError.badReply("The Pi did not include its ambient settings.")
        }
        throw AmbientError.timedOut
    }

    private func decodeSnapshot(_ value: Any) -> AmbientSnapshot? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(AmbientSnapshot.self, from: data)
    }
}

enum GeoLookup {
    static func search(_ query: String) async throws -> [GeoCity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw AmbientError.geo("Bad search.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AmbientError.geo("The place service did not answer.")
        }
        struct Envelope: Decodable { let results: [GeoCity]? }
        return try JSONDecoder().decode(Envelope.self, from: data).results ?? []
    }
}
