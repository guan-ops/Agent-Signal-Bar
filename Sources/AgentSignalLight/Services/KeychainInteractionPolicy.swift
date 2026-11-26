import AgentSignalKeychainShim
import Foundation
import Security

/// LAContext alone does not suppress the file-based login keychain's ACL dialogs.
/// Serialize synchronous Security calls and restore the legacy UI setting before leaving the scope.
/// No access rights are changed; protected items fail closed when interaction is disabled.
/// The legacy switch lives in the AgentSignalKeychainShim C target so its deprecation warning
/// is contained there; Apple offers no non-deprecated API with the same effect.
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
        var previous = false
        let readStatus = ASLLegacyKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = ASLLegacyKeychainSetUserInteractionAllowed(false)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { _ = ASLLegacyKeychainSetUserInteractionAllowed(previous) }
        return operation()
    }

    /// Current value of the process-wide switch; nil if Security could not report it.
    /// Reads only this process's setting and never touches keychain items.
    static var isInteractionAllowed: Bool? {
        var allowed = false
        return ASLLegacyKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess ? allowed : nil
    }
}
