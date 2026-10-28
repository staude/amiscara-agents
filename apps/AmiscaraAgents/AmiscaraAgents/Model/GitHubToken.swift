#if !os(tvOS)
import Foundation
import Security

/// The GitHub token of a host (#309) in the Keychain of this device, one
/// item per host. It lets the app show and merge the pull requests of the
/// host's spaces. Never synced through iCloud, like secrets (#291).
enum GitHubToken {
    private static let service = "net.staude.amiscara.agents.github-token"

    static func save(_ token: String, host hostID: UUID) throws {
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

    static func load(host hostID: UUID) -> String? {
        var query = baseQuery(hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    static func delete(host hostID: UUID) {
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
