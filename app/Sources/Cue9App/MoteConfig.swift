import Foundation

/// The JSON that `cue9_pi_setup.sh` prints. The mote's key lives here too; the
/// file is 0600 and never shown in the UI.
struct PiSummary: Codable {
    let host: String
    let port: Int
    let ca: String
    let moteCert: String
    let moteKey: String
    let bridge: String?
    let user: String?

    enum CodingKeys: String, CodingKey {
        case host, port, ca, bridge, user
        case moteCert = "mote_cert"
        case moteKey = "mote_key"
    }

    var bridgeTarget: String {
        if let bridge, !bridge.isEmpty { return bridge }
        return "\(user ?? "pi")@\(host)"
    }
}

struct MoteConfig: Codable {
    struct WiFi: Codable {
        let ssid: String
        let psk: String
    }

    let wifi: WiFi
    let host: String
    let port: Int
    let ca: String
    let cert: String
    let key: String
}

enum MoteProvisioning {
    static func loadSummary() -> PiSummary? {
        guard let data = try? Data(contentsOf: CuePaths.piSummary) else { return nil }
        return try? JSONDecoder().decode(PiSummary.self, from: data)
    }

    static func saveSummary(_ data: Data) throws {
        try data.write(to: CuePaths.piSummary, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: CuePaths.piSummary.path
        )
    }

    /// `CUE9CFG1\n` + JSON, zero-padded to the 16 KB cue9cfg partition.
    static func configData(summary: PiSummary, ssid: String, psk: String) throws -> Data {
        let config = MoteConfig(
            wifi: .init(ssid: ssid, psk: psk),
            host: summary.host,
            port: summary.port,
            ca: summary.ca,
            cert: summary.moteCert,
            key: summary.moteKey
        )
        var blob = Data("CUE9CFG1\n".utf8)
        blob.append(try JSONEncoder().encode(config))
        if blob.count < 16_384 {
            blob.append(Data(repeating: 0, count: 16_384 - blob.count))
        }
        return blob
    }
}
