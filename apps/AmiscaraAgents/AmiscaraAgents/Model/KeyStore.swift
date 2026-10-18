import Foundation
import Security

/// Private SSH keys in the login Keychain, one item per host.
enum KeyStore {
    private static let service = "net.staude.amiscara.agents.ssh-key"

    enum Failure: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return String(localized: "Keychain: \(message)")
            }
        }
    }

    static func save(privateKey: String, for hostID: UUID) throws {
        let data = Data(privateKey.utf8)
        let query = baseQuery(hostID)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Amiscara Agents SSH key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func load(for hostID: UUID) throws -> String? {
        var query = baseQuery(hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure.status(status)
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
