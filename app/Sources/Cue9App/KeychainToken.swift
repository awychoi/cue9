import Foundation
import Security

/// Per-install app credential for the local cue9 phone plugin.
///
/// The raw token never leaves the Keychain. The plugin stores only its SHA-256.
enum KeychainToken {
    static let service = "com.cue9.app"
    static let account = "dsh-app-token"
    static let label = "cue9 app token — local phone setup"
    static let itemDescription = "Lets the cue9 Mac app configure the local phone link, pairing, notifications, and keep-awake. Not your DSH, Tailscale, website, or iPhone password."

    private static let byteCount = 32

    /// Load the existing token, or create and store a new one.
    static func loadOrCreate() -> String? {
        if let existing = load() {
            updateMetadata()
            return existing
        }
        return create()
    }

    /// Name the item in the system prompt. Existing items created by earlier
    /// builds get the same descriptive label/description without changing data.
    private static func updateMetadata() {
        let attributes = [
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: itemDescription,
        ] as CFDictionary
        _ = SecItemUpdate(baseQuery() as CFDictionary, attributes)
    }

    /// Read the token without creating one.
    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Remove the token. Returns false only when the Keychain refused.
    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete and mint a fresh token. Returns nil when the Keychain is unavailable.
    static func reset() -> String? {
        guard delete() else { return nil }
        return create()
    }

    /// Mint a token in memory without storing it. Used by the rotate flow so the
    /// old token remains valid until the plugin acknowledges the new one.
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Persist a token, replacing the existing item in place when possible.
    static func store(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: itemDescription,
        ] as CFDictionary
        let updated = SecItemUpdate(baseQuery() as CFDictionary, update)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = label
        query[kSecAttrDescription as String] = itemDescription
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func create() -> String? {
        guard let token = generate(), store(token) else { return nil }
        return token
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
