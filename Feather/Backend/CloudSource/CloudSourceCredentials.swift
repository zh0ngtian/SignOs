import Foundation
import Security

enum CloudSourceCredentials {
    private static func query(for endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.signos.app.cloud-source",
         kSecAttrAccount as String: endpoint.host?.lowercased() ?? endpoint.absoluteString]
    }

    static func read(for endpoint: URL) -> String? {
        var query = query(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for endpoint: URL) throws {
        let query = query(for: endpoint)
        let data = Data(token.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if result != errSecSuccess { throw failure() }
    }

    static func remove(for endpoint: URL) { SecItemDelete(query(for: endpoint) as CFDictionary) }

    private static func failure() -> NSError {
        NSError(domain: "CloudSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "管理 Token 无法保存到钥匙串"])
    }
}
