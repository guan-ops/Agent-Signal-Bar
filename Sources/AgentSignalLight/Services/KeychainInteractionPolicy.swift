import Foundation
import Security

/// LAContext alone does not suppress the file-based login keychain's ACL dialogs.
/// Serialize synchronous Security calls and restore the legacy UI setting before leaving the scope.
/// No access rights are changed; protected items fail closed when interaction is disabled.
enum KeychainInteractionPolicy {
    private static let lock = NSRecursiveLock()

    /// The switch below is process-wide. Third-party code that reads the keychain itself
    /// (browser cookie import) runs here so a concurrent silent read cannot suppress its prompt.
    static func whileInteractionAllowed<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }

    static func perform(allowInteraction: Bool, _ operation: () -> OSStatus) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if allowInteraction { return operation() }
        var previous: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(false)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
