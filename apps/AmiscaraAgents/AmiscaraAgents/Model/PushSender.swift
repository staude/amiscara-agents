#if os(macOS)
import CryptoKit
import Foundation
import Observation
import Security

/// Sends "agent waits / is done" as APNs pushes to the iPhones and iPads
/// registered on this Mac (#94), so they arrive while the iOS app sleeps and
/// reach a paired Apple Watch, with answer buttons. Only for the local host:
/// devices register by writing `~/.amiscara-agents/push/<id>.json` here.
///
/// Needs an APNs key (.p8) of the team; it stays in the login Keychain.
@MainActor
@Observable
final class PushSender {
    static let team = "7N2W4T6UPV"
    static let topic = "net.staude.amiscara.agents"

    private(set) var keyID: String? = UserDefaults.standard.string(forKey: "apnsKeyID")
    /// The last failure, for the settings.
    private(set) var lastError: String?
    @ObservationIgnored private var bearer: (token: String, made: Date)?

    var configured: Bool { keyID != nil && loadKey() != nil }

    /// Registered devices, newest first.
    var devices: [PushDevice] {
        deviceFiles().map(\.device).sorted { $0.updated > $1.updated }
    }

    // MARK: Key

    func setKey(pem: String, keyID: String) throws {
        let keyID = keyID.trimmingCharacters(in: .whitespaces)
        guard keyID.count == 10 else { throw Failure.keyID }
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        try Keychain.save(Data(pem.utf8), account: keyID)
        if let old = self.keyID, old != keyID { Keychain.delete(account: old) }
        UserDefaults.standard.set(keyID, forKey: "apnsKeyID")
        self.keyID = keyID
        bearer = nil
        lastError = nil
    }

    func removeKey() {
        if let keyID { Keychain.delete(account: keyID) }
        UserDefaults.standard.removeObject(forKey: "apnsKeyID")
        keyID = nil
        bearer = nil
    }

    // MARK: Sending

    /// One push per item and device, like the local notifications.
    func send(_ items: [BoardItem]) {
        guard configured, !items.isEmpty else { return }
        let files = deviceFiles()
        guard !files.isEmpty else { return }
        for item in items {
            for file in files {
                let content = AgentNotificationText(item: item, hostName: file.device.hostName)
                let payload = Self.payload(content, blocked: item.agentState == .blocked, device: file.device, item: item)
                Task {
                    await post(
                        payload,
                        to: file,
                        collapseID: AgentNotification.identifier(file.device.hostID, item.paneId),
                        urgent: item.agentState == .blocked
                    )
                }
            }
        }
    }

    /// A test push to every registered device.
    func sendTest() async {
        for file in deviceFiles() {
            let payload: [String: Any] = ["aps": [
                "alert": [
                    "title": String(localized: "Amiscara Agents"),
                    "body": String(localized: "Test vom Mac: Push kommt an."),
                ],
                "sound": "default",
            ]]
            await post(payload, to: file, collapseID: "test", urgent: true)
        }
    }

    private static func payload(_ text: AgentNotificationText, blocked: Bool, device: PushDevice, item: BoardItem) -> [String: Any] {
        var aps: [String: Any] = [
            "alert": ["title": text.title, "subtitle": text.subtitle, "body": text.body],
            "thread-id": device.hostID.uuidString,
        ]
        if blocked {
            aps["sound"] = "default"
            aps["category"] = AgentNotification.blockedCategory
        }
        return [
            "aps": aps,
            "host": device.hostID.uuidString,
            "workspace": item.workspaceId,
            "pane": item.paneId,
        ]
    }

    private func post(_ payload: [String: Any], to file: DeviceFile, collapseID: String, urgent: Bool) async {
        guard let token = authorization() else { return }
        let base = file.device.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com"
        guard let url = URL(string: "\(base)/3/device/\(file.device.token)"),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(Self.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(urgent ? "10" : "5", forHTTPHeaderField: "apns-priority")
        request.setValue(String(collapseID.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                lastError = nil
                return
            }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
            // The app was removed or the token is from another environment.
            if status == 410 || reason == "BadDeviceToken" || reason == "Unregistered" {
                try? FileManager.default.removeItem(at: file.url)
            }
            if reason == "ExpiredProviderToken" { bearer = nil }
            lastError = String(localized: "APNs: \(reason) (\(file.device.deviceName))")
        } catch {
            lastError = String(localized: "APNs: \(error.localizedDescription)")
        }
    }

    /// The provider token (JWT, ES256), renewed after 50 minutes; Apple
    /// accepts one for an hour.
    private func authorization() -> String? {
        if let bearer, Date.now.timeIntervalSince(bearer.made) < 50 * 60 { return bearer.token }
        guard let keyID, let pem = loadKey(), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            lastError = String(localized: "Kein APNs-Schlüssel hinterlegt.")
            return nil
        }
        let header = Self.base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = Self.base64URL(Data(#"{"iss":"\#(Self.team)","iat":\#(Int(Date.now.timeIntervalSince1970))}"#.utf8))
        let input = "\(header).\(claims)"
        guard let signature = try? key.signature(for: Data(input.utf8)) else { return nil }
        let token = "\(input).\(Self.base64URL(signature.rawRepresentation))"
        bearer = (token, .now)
        return token
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func loadKey() -> String? {
        keyID.flatMap { Keychain.load(account: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Devices

    private struct DeviceFile {
        let url: URL
        let device: PushDevice
    }

    /// Devices refresh their registration with every session; one not seen
    /// for this long is dropped.
    private static let expiry: TimeInterval = 30 * 24 * 3600

    private func deviceFiles() -> [DeviceFile] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: pushDir())
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let device = try? JSONDecoder().decode(PushDevice.self, from: data)
            else { return nil }
            if Date.now.timeIntervalSince(device.updated) > Self.expiry {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return DeviceFile(url: url, device: device)
        }
    }

    /// Stops pushes to a device until it registers again.
    func remove(_ device: PushDevice) {
        for file in deviceFiles() where file.device.token == device.token {
            try? FileManager.default.removeItem(at: file.url)
        }
        lastError = nil
    }

    enum Failure: LocalizedError {
        case keyID

        var errorDescription: String? {
            String(localized: "Die Key-ID hat zehn Zeichen, z. B. ABC123DEFG.")
        }
    }

    /// The .p8 key in the login Keychain.
    private enum Keychain {
        static let service = "net.staude.amiscara.agents.apns-key"

        static func save(_ data: Data, account: String) throws {
            let query = base(account)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "Amiscara Agents APNs key"
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeyStore.Failure.status(status) }
        }

        static func load(account: String) -> Data? {
            var query = base(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        static func delete(account: String) {
            SecItemDelete(base(account) as CFDictionary)
        }

        private static func base(_ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
        }
    }
}
#endif
