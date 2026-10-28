import Foundation
import Security

/// Values of secrets for hosts (#291) in the Keychain of this device, one
/// item per host and name, so a secret can be sent again, e.g. after the
/// host was set up anew. Never synced through iCloud.
enum SecretStore {
    private static let service = "net.staude.amiscara.agents.secret"

    static func save(value: String, name: String, host hostID: UUID) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account(hostID, name))
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Amiscara Agents secret \(name)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStore.Failure.status(status) }
    }

    static func load(name: String, host hostID: UUID) throws -> String? {
        var query = baseQuery(account(hostID, name))
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

    static func delete(name: String, host hostID: UUID) {
        SecItemDelete(baseQuery(account(hostID, name)) as CFDictionary)
    }

    /// The names with a value on this device for the host, sorted.
    static func names(for hostID: UUID) -> [String] {
        let prefix = hostID.uuidString + "/"
        return accounts().compactMap { account in
            account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : nil
        }
        .sorted()
    }

    /// Forgets all secrets of a removed host.
    static func deleteAll(for hostID: UUID) {
        for name in names(for: hostID) {
            delete(name: name, host: hostID)
        }
    }

    /// The accounts of all secret items, without their values.
    private static func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func account(_ hostID: UUID, _ name: String) -> String {
        "\(hostID.uuidString)/\(name)"
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
