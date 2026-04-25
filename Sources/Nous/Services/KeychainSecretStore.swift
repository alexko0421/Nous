import Foundation
import Security

protocol SecretStore: AnyObject {
    var storageDescription: String { get }
    func string(for account: String) -> String?
    func setString(_ value: String?, for account: String)
}

final class VolatileSecretStore: SecretStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    let storageDescription = "Stored only in memory for tests."

    func string(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func setString(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.isEmpty {
            values[account] = value
        } else {
            values.removeValue(forKey: account)
        }
    }
}

final class UserDefaultsSecretStore: SecretStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    let storageDescription = "Stored locally for this debug build to avoid repeated macOS password prompts. Release builds still use macOS Keychain."

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "nous.debug.secret."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func string(for account: String) -> String? {
        defaults.string(forKey: storageKey(for: account))
    }

    func setString(_ value: String?, for account: String) {
        let key = storageKey(for: account)
        guard let value, !value.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(value, forKey: key)
    }

    private func storageKey(for account: String) -> String {
        keyPrefix + account
    }
}

final class KeychainSecretStore: SecretStore {
    private let service: String

    let storageDescription = "Stored locally in macOS Keychain."

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).secrets" } ?? "com.nous.app.Nous.secrets") {
        self.service = service
    }

    func string(for account: String) -> String? {
        let query = baseQuery(for: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func setString(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(baseQuery(for: account) as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemCopyMatching(
            query.merging([
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new } as CFDictionary,
            nil
        )

        if status == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            return
        }

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
