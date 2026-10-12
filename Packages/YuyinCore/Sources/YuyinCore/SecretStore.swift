import Foundation
import Security

public enum SecretKey: String, Sendable {
    case funASRKey = "funasr.apiKey"
}

public protocol SecretStore: AnyObject, Sendable {
    func read(_ key: SecretKey) -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey)
}

public struct SecretStoreError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
        return "钥匙串写入失败：\(detail)"
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "app.yuyin.client") {
        self.service = service
    }

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public func read(_ key: SecretKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError(status: status)
        }
    }

    public func delete(_ key: SecretKey) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    public init() {}

    public func read(_ key: SecretKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func write(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: SecretKey) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}
