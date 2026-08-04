import Foundation
import Security

/// Keychain storage for the user-supplied Anthropic API key (ADR 0011).
/// The key is device-only (never synced or restored to another device) and
/// is the sole credential cloud assist ever uses — no server holds it.
enum CloudAssistKeyStore {
    private static let service = "\(AppConfig.bundleID).cloud-assist"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudAssistError.api("Could not store the API key in the Keychain (\(status)).")
        }
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static var hasKey: Bool { load() != nil }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
