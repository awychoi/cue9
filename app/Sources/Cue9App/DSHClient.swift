import Foundation

private struct DSHServerFailure: Decodable {
    let error: String?
}

private struct DSHAppRegistrationResponse: Decodable {
    let ok: Bool?
    let status: String?
    let error: String?
}

struct DSHPluginAction: Codable, Hashable {
    let id: String
    let label: String
    let map: [String]?
}

struct DSHPluginAnimation: Codable, Hashable {
    let id: String
    let label: String
    var deviceOnly: Bool? = nil
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

    struct Behaviour: Decodable {
        let sensitivity: Int?
        let dizzyMs: Int?
        let happyMs: Int?
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
    let behaviour: Behaviour?
    let palette: [String: String]?
    let backgrounds: [String: String]?
}


struct PhonePowerState: Decodable, Equatable {
    let enabled: Bool?
    let active: Bool?
    let working: Int?
    let waiting: Int?
    let reason: String?
}

struct PhonePushResult: Decodable {
    let ok: Bool?
    let sent: Int?
    let failed: Int?
    let error: String?
}

/// Result of removing this Mac's phone link. No secrets are returned.
struct PhoneSetupResetResult: Decodable, Equatable {
    let ok: Bool?
    let revoked: Int?
    let serveReset: Bool?
    let warning: String?
}

enum AppRegistrationResult: Equatable {
    case created
    case ok
    case conflict
}

/// One phone paired with this Mac. Timestamps are raw (milliseconds or seconds).
struct PhoneDevice: Decodable, Equatable, Identifiable {
    let id: String
    let createdAt: Double?
    let lastSeenAt: Double?

    init(id: String, createdAt: Double? = nil, lastSeenAt: Double? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = Self.flexibleTimestamp(container, .createdAt)
        lastSeenAt = Self.flexibleTimestamp(container, .lastSeenAt)
    }

    private static func flexibleTimestamp(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) {
            if let number = Double(value) { return number }
            if let date = ISO8601DateFormatter().date(from: value) {
                return date.timeIntervalSince1970 * 1000
            }
        }
        return nil
    }
}

/// A one-time pairing link minted by the authenticated app.
/// The raw token is held only in memory and never fetched from a status route.
struct PhonePairing: Decodable, Equatable {
    let url: String
    let token: String
    let expiresAt: Double?

    init(url: String, token: String, expiresAt: Double? = nil) {
        self.url = url
        self.token = token
        self.expiresAt = expiresAt
    }

    var expiresAtDate: Date? {
        guard let expiresAt, expiresAt > 0 else { return nil }
        let seconds = expiresAt > 1_000_000_000_000 ? expiresAt / 1000 : expiresAt
        return Date(timeIntervalSince1970: seconds)
    }

    var isExpired: Bool {
        guard let date = expiresAtDate else { return false }
        return date <= Date()
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case token
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        if let value = try? container.decode(Double.self, forKey: .expiresAt) {
            expiresAt = value
        } else if let value = try? container.decode(Int.self, forKey: .expiresAt) {
            expiresAt = Double(value)
        } else if let value = try? container.decode(String.self, forKey: .expiresAt) {
            if let number = Double(value) {
                expiresAt = number
            } else if let date = ISO8601DateFormatter().date(from: value) {
                expiresAt = date.timeIntervalSince1970 * 1000
            } else {
                expiresAt = nil
            }
        } else {
            expiresAt = nil
        }
    }
}

struct PhoneSetupState: Decodable, Equatable {
    struct Tailscale: Decodable, Equatable {
        let running: Bool?
        let online: Bool?
        let dnsName: String?
        let iosDevices: Int?
        let iosOnline: Int?
        let error: String?
        let adminUrl: String?
        let appPath: String?
    }

    struct HTTPS: Decodable, Equatable {
        let ready: Bool?
        let certFile: String?
        let keyFile: String?
        let expiresAt: String?
        let daysRemaining: Int?
        let renewSoon: Bool?
    }

    struct Serve: Decodable, Equatable {
        let active: Bool?
        let port: Int?
        let url: String?
    }

    struct LocalDNS: Decodable, Equatable {
        let name: String?
        let address: String?
    }

    struct Config: Decodable, Equatable {
        let publicOrigin: String?
        let port: Int?
    }

    struct Phone: Decodable, Equatable {
        let paired: Bool?
        let clients: Int?
        let lastSeenAt: Double?
        let push: Bool?
        let devices: [PhoneDevice]?
    }

    struct Pairing: Decodable, Equatable {
        let ready: Bool?
        let origin: String?
    }

    let ok: Bool?
    let tailscale: Tailscale?
    let https: HTTPS?
    let serve: Serve?
    let localDns: LocalDNS?
    let config: Config?
    let phone: Phone?
    let pairing: Pairing?
    let canApply: Bool?
}

enum DSHClientError: LocalizedError {
    case badURL
    case badStatus(Int)
    case server(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL: return "The DSH address is not valid."
        case .badStatus(let code): return "DSH returned HTTP \(code)."
        case .server(let message): return message
        case .decode: return "DSH returned an unexpected response."
        }
    }
}

struct DSHClient {
    var baseURL: URL
    var appToken: String

    init(baseURL: URL = URL(string: "http://127.0.0.1:53614")!, appToken: String = "") {
        self.baseURL = baseURL
        self.appToken = appToken
    }

    private func authorize(_ request: inout URLRequest) {
        guard !appToken.isEmpty else { return }
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
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

    func behaviour(sensitivity: Int, dizzyMs: Int, happyMs: Int) async throws -> DSHPluginState {
        try await post("plugins/cue9/behaviour", body: [
            "behaviour": ["sensitivity": sensitivity, "dizzyMs": dizzyMs, "happyMs": happyMs],
        ])
    }

    private func getJSON<T: Decodable>(
        _ path: String,
        timeout: TimeInterval,
        authorized: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authorized { authorize(&request) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DSHClientError.badStatus(http.statusCode)
            }
            if let failure = try? JSONDecoder().decode(DSHServerFailure.self, from: data),
               let message = failure.error, !message.isEmpty {
                throw DSHClientError.server(message)
            }
            throw DSHClientError.badStatus(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw DSHClientError.decode
        }
        return value
    }

    private func postJSON<T: Decodable>(
        _ path: String,
        body: [String: Any],
        timeout: TimeInterval,
        header: String,
        authorized: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: header)
        if authorized { authorize(&request) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DSHClientError.badStatus(http.statusCode)
            }
            if let failure = try? JSONDecoder().decode(DSHServerFailure.self, from: data),
               let message = failure.error, !message.isEmpty {
                throw DSHClientError.server(message)
            }
            throw DSHClientError.badStatus(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw DSHClientError.decode
        }
        return value
    }

    /// Register this Mac's app token with the plugin. No Bearer is sent:
    /// the token itself is the request body, and the route is loopback + Host fenced.
    func registerApp(token: String) async throws -> AppRegistrationResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("plugins/cue9-phone/app/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-cue9-phone")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        if http.statusCode == 409 { return .conflict }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DSHClientError.badStatus(http.statusCode)
            }
            if let failure = try? JSONDecoder().decode(DSHServerFailure.self, from: data),
               let message = failure.error, !message.isEmpty {
                throw DSHClientError.server(message)
            }
            throw DSHClientError.badStatus(http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(DSHAppRegistrationResponse.self, from: data) else {
            return .ok
        }
        if value.ok == false {
            if value.error == "conflict" { return .conflict }
            throw DSHClientError.server(value.error ?? "The phone plugin rejected this Mac's app registration.")
        }
        return value.status == "created" ? .created : .ok
    }

    /// Rotate this Mac's app token. Authenticated with the current app token;
    /// the body carries the replacement. The Host returns 200 / 401 / 400.
    func rotateAppToken(newToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("plugins/cue9-phone/app/rotate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-cue9-phone")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": newToken])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            throw DSHClientError.badStatus(http.statusCode)
        }
    }

    /// Mint a one-time pairing link. The response contains the only copy of the raw token.
    func createPhonePairing() async throws -> PhonePairing {
        try await postJSON(
            "plugins/cue9-phone/setup/pairing",
            body: [:],
            timeout: 8,
            header: "x-cue9-phone"
        )
    }

    /// Revoke one paired phone, or all phones when `deviceId` is nil.
    /// The response body is not required: the caller refreshes setup afterwards.
    func revokePhone(deviceId: String?) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("plugins/cue9-phone/setup/revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-cue9-phone")
        authorize(&request)
        var body: [String: Any] = [:]
        if let deviceId, !deviceId.isEmpty { body["deviceId"] = deviceId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DSHClientError.badStatus(http.statusCode)
            }
            if let failure = try? JSONDecoder().decode(DSHServerFailure.self, from: data),
               let message = failure.error, !message.isEmpty {
                throw DSHClientError.server(message)
            }
            throw DSHClientError.badStatus(http.statusCode)
        }
    }

    /// Remove the phone link, phones, pairing links, notifications and phone
    /// config. The app's Keychain credential and Tailscale are untouched.
    func resetPhoneSetup() async throws -> PhoneSetupResetResult {
        try await postJSON(
            "plugins/cue9-phone/setup/reset",
            body: [:],
            timeout: 45,
            header: "x-cue9-phone"
        )
    }

    func phonePower() async throws -> PhonePowerState {
        try await getJSON("plugins/cue9-phone/power", timeout: 2)
    }

    func setPhonePower(_ enabled: Bool) async throws -> PhonePowerState {
        try await postJSON(
            "plugins/cue9-phone/power",
            body: ["enabled": enabled],
            timeout: 3,
            header: "x-cue9-phone"
        )
    }

    func phoneSetup() async throws -> PhoneSetupState {
        try await getJSON("plugins/cue9-phone/setup", timeout: 12)
    }

    func applyPhoneSetup() async throws -> PhoneSetupState {
        try await postJSON(
            "plugins/cue9-phone/setup/apply",
            body: [:],
            timeout: 90,
            header: "x-cue9-phone"
        )
    }

    /// The test endpoint uses HTTP 400 for a real push failure but still returns
    /// structured `{ok:false,error,failed}` data. Decode that instead of reducing
    /// every rejection to a generic HTTP error.
    func testPhonePush() async throws -> PhonePushResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("plugins/cue9-phone/setup/test-push"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-cue9-phone")
        authorize(&request)
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHClientError.decode }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DSHClientError.badStatus(http.statusCode)
        }
        if (200..<300).contains(http.statusCode) {
            guard let value = try? JSONDecoder().decode(PhonePushResult.self, from: data) else {
                throw DSHClientError.decode
            }
            return value
        }
        if (400..<500).contains(http.statusCode),
           let value = try? JSONDecoder().decode(PhonePushResult.self, from: data),
           value.error != nil || value.failed != nil || value.ok != nil {
            return value
        }
        if let failure = try? JSONDecoder().decode(DSHServerFailure.self, from: data),
           let message = failure.error, !message.isEmpty {
            throw DSHClientError.server(message)
        }
        throw DSHClientError.badStatus(http.statusCode)
    }
}
