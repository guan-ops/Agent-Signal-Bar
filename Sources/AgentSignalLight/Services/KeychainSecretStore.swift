import Foundation
import Security

protocol SecretStoring: Sendable {
    func data(for key: String) throws -> Data?
    func string(for key: String) throws -> String?
    func set(_ data: Data, for key: String) throws
    func set(_ string: String, for key: String) throws
    func delete(key: String) throws
}

final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                return "Keychain operation failed with status \(status)."
            }
        }
    }

    private let service: String
    private let accessGroup: String?

    init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.unexpectedStatus(status)
        }
        return result as? Data
    }

    func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ data: Data, for key: String) throws {
        var query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(updateStatus)
        }

        attributes.forEach { query[$0.key] = $0.value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.unexpectedStatus(addStatus)
        }
    }

    func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

final class FileSecretStore: SecretStoring, @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func data(for key: String) throws -> Data? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ data: Data, for key: String) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }

    func delete(key: String) throws {
        let url = fileURL(for: key)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for key: String) -> URL {
        let safeName = key
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
                    ? String(scalar)
                    : "_"
            }
            .joined()
        return rootURL.appendingPathComponent(safeName, isDirectory: false)
    }
}
