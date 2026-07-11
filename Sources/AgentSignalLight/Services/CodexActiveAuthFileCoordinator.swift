import Foundation

enum CodexActiveAuthFileCoordinator {
    private static let lock = NSRecursiveLock()
    private nonisolated(unsafe) static var pendingRefreshedAuthData: [String: Data] = [:]

    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static func rememberRefreshedAuthData(
        _ data: Data,
        replacingAuthFingerprint authFingerprint: String
    ) {
        withLock {
            pendingRefreshedAuthData[authFingerprint] = data
        }
    }

    static func refreshedAuthData(
        replacingAuthFingerprint authFingerprint: String
    ) -> Data? {
        withLock {
            pendingRefreshedAuthData[authFingerprint]
        }
    }

    static func clearRefreshedAuthData(
        replacingAuthFingerprint authFingerprint: String
    ) {
        withLock {
            _ = pendingRefreshedAuthData.removeValue(forKey: authFingerprint)
        }
    }
}

protocol CodexRefreshedCredentialPersisting: Sendable {
    func persistRefreshedAuthData(
        _ data: Data,
        replacingAuthFingerprint authFingerprint: String
    ) throws
}
