#if !os(tvOS)
import Foundation
import Security

/// A GitHub token per host (#296) in the Keychain of this device, for the
/// plans waiting for approval in the host's repositories. Like the secrets
/// (#291) never synced through iCloud, so each device gets it once.
enum GitHubToken {
    private static let service = "net.staude.amiscara.agents.github-token"

    static func save(_ token: String, for hostID: UUID) throws {
        let data = Data(token.utf8)
        let query = baseQuery(hostID)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Amiscara Agents GitHub token"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStore.Failure.status(status) }
    }

    static func load(for hostID: UUID) throws -> String? {
        var query = baseQuery(hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeyStore.Failure.status(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for hostID: UUID) {
        SecItemDelete(baseQuery(hostID) as CFDictionary)
    }

    private static func baseQuery(_ hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }
}
#endif
