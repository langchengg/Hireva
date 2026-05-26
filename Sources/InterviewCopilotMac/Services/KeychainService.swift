import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .invalidData:
            return "The saved keychain item could not be read."
        }
    }
}

final class KeychainService {
    private let legacyService = "InterviewCopilotMac"
    private let legacyAccount = "DeepSeekAPIKey"
    private let providerService = "InterviewCopilotMac.LLMProviderKeys"

    func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, account: "deepseek.default")
    }

    func loadAPIKey() throws -> String? {
        if let providerKey = try loadAPIKey(account: "deepseek.default") {
            return providerKey
        }
        return try loadGenericPassword(service: legacyService, account: legacyAccount)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(account: "deepseek.default")
        try deleteGenericPassword(service: legacyService, account: legacyAccount)
    }

    func saveAPIKey(_ apiKey: String, account: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        try saveGenericPassword(data: data, service: providerService, account: account)
    }

    func loadAPIKey(account: String) throws -> String? {
        try loadGenericPassword(service: providerService, account: account)
    }

    func deleteAPIKey(account: String) throws {
        try deleteGenericPassword(service: providerService, account: account)
    }

    func hasAPIKey(account: String) -> Bool {
        ((try? loadAPIKey(account: account)) ?? nil)?.isEmpty == false
    }

    func hasAPIKey() -> Bool {
        ((try? loadAPIKey()) ?? nil)?.isEmpty == false
    }

    private func saveGenericPassword(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(status)
    }

    private func loadGenericPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    private func deleteGenericPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

protocol APIKeyStore: AnyObject {
    func saveAPIKey(_ apiKey: String, account: String) throws
    func loadAPIKey(account: String) throws -> String?
    func deleteAPIKey(account: String) throws
}

extension KeychainService: APIKeyStore {}
