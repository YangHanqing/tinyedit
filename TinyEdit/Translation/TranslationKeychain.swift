import Foundation
import Security
import LocalAuthentication

/// Bind each credential to its full endpoint: changing hosts cannot reuse an old key silently.
enum TranslationKeychain {
    private static func query(endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "cn.hqyang.tinyedit") + ".translation",
         kSecAttrAccount as String: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Check presence without loading the secret into the settings view or displaying authentication UI.
    static func contains(endpoint: String) throws -> Bool {
        var q = query(endpoint: endpoint)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw TranslationFailure.keychain }
        return true
    }

    static func read(endpoint: String) throws -> String {
        var q = query(endpoint: endpoint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw TranslationFailure.keychain
        }
        return key
    }

    // Off the main thread: if Keychain asks the user for access (for example after the app was re-signed),
    // the window keeps responding while the prompt waits.
    static func containsInBackground(endpoint: String) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) { try contains(endpoint: endpoint) }.value
    }

    static func readInBackground(endpoint: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try read(endpoint: endpoint) }.value
    }

    static func saveInBackground(_ key: String, endpoint: String) async throws {
        try await Task.detached(priority: .userInitiated) { try save(key, endpoint: endpoint) }.value
    }

    static func save(_ key: String, endpoint: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query(endpoint: endpoint)
        if trimmed.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationFailure.keychain }
            return
        }
        let value = [kSecValueData as String: Data(trimmed.utf8)]
        var status = SecItemUpdate(q as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = q.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranslationFailure.keychain }
    }
}
