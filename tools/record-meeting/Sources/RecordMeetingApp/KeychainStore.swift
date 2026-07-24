import Foundation
import Security

enum SecretKey: String {
    case huggingFaceToken
    case notionToken
}

struct KeychainStore {
    static let service = "com.mikerosoft.record-meeting"

    func read(_ key: SecretKey) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    func write(_ value: String, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }

        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RecordMeetingError.message("Could not save the secret in Keychain (OSStatus \(status)).")
        }
    }
}
