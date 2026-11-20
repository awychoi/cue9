import Foundation

struct DSHPluginAction: Codable, Hashable {
    let id: String
    let label: String
    let map: [String]?
}

struct DSHPluginAnimation: Codable, Hashable {
    let id: String
    let label: String
}

struct DSHPluginState: Decodable {
    struct Status: Decodable {
        let connected: Bool?
        let port: String?
        let error: String?
        let link: String?
        let target: String?
        let peer: String?
        let rssi: Int?
        let keepAwake: Bool?
    }

    struct Link: Decodable {
        let transport: String?
        let host: String?
        let attach: String?
        let keepAwake: Bool?
    }

    let current: String?
    let currentAnim: String?
    let previewing: Bool?
    let agents: Int?
    let keys: Int?
    let mapping: [String: [String]]?
    let actions: [DSHPluginAction]?
    let animations: [DSHPluginAnimation]?
    let status: Status?
    let link: Link?
}

enum DSHClientError: LocalizedError {
    case badURL
    case badStatus(Int)
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL: return "The DSH address is not valid."
        case .badStatus(let code): return "DSH returned HTTP \(code)."
        case .decode: return "DSH returned an unexpected response."
        }
    }
}

struct DSHClient {
    var baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:53614")!) {
        self.baseURL = baseURL
    }

    func state() async throws -> DSHPluginState {
        var request = URLRequest(url: baseURL.appendingPathComponent("plugins/cue9/state"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard http.statusCode == 200 else { throw DSHClientError.badStatus(http.statusCode) }
        guard let value = try? JSONDecoder().decode(DSHPluginState.self, from: data) else {
            throw DSHClientError.decode
        }
        return value
    }

    func post(_ path: String, body: [String: Any]) async throws -> DSHPluginState {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-cue9-action")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard http.statusCode == 200 else { throw DSHClientError.badStatus(http.statusCode) }
        guard let value = try? JSONDecoder().decode(DSHPluginState.self, from: data) else {
            throw DSHClientError.decode
        }
        return value
    }

    func mapping(_ value: [String: [String]]) async throws -> DSHPluginState {
        try await post("plugins/cue9/mapping", body: ["mapping": value])
    }

    func preview(action: String, animation: String) async throws -> DSHPluginState {
        try await post("plugins/cue9/preview", body: ["action": action, "animation": animation])
    }

    func resumeLive() async throws -> DSHPluginState {
        try await post("plugins/cue9/live", body: [:])
    }

    func setUSB(_ enabled: Bool) async throws -> DSHPluginState {
        try await post("plugins/cue9/usb", body: ["enabled": enabled])
    }

    func setLink(
        transport: String,
        host: String? = nil,
        keepAwake: Bool? = nil,
        key: String? = nil
    ) async throws -> DSHPluginState {
        var body: [String: Any] = ["transport": transport]
        if let host, !host.isEmpty { body["host"] = host }
        if let keepAwake { body["keepAwake"] = keepAwake }
        if let key, !key.isEmpty { body["key"] = key }
        return try await post("plugins/cue9/link", body: body)
    }

    func palette(_ value: [String: String], backgrounds: [String: String]) async throws -> DSHPluginState {
        try await post("plugins/cue9/palette", body: ["palette": value, "backgrounds": backgrounds])
    }
}
