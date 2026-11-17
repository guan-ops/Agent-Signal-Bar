import Foundation

// Follows CodexBar ProviderVersionDetector / ClaudeOAuthUsageFetcher (7447bc7): report the
// installed Claude Code version instead of a fixed one. MIT; see Resources/ClaudeSupport-LICENSE.txt.
enum ClaudeCodeVersion {
    static let fallback = "2.1.0"
    static let cacheTTL: TimeInterval = 30 * 60

    private struct Fingerprint: Equatable {
        let path: String
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (fingerprint: Fingerprint, version: String, cachedAt: Date)?

    /// First token of `claude --version`, limited to characters that are safe inside a header value.
    static func normalized(_ raw: String?) -> String? {
        guard let token = raw?.split(whereSeparator: \.isWhitespace).first.map(String.init),
              !token.isEmpty, token.utf8.count <= 32,
              token.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-+_".unicodeScalars.contains($0)) })
        else { return nil }
        return token
    }

    /// The cached version is keyed by the resolved executable, so an upgrade is noticed without
    /// running anything. The CLI itself is only started when `allowExecution` is true: a manual
    /// refresh, or after the user enabled background CLI runs.
    static func detect(binary: URL, allowExecution: Bool, now: Date = Date(),
                       run: (URL) -> String? = runVersionCommand) -> String? {
        let resolved = binary.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        let fingerprint = Fingerprint(path: resolved.path, modified: modified, size: size, inode: inode)
        lock.lock(); defer { lock.unlock() }
        if let cache, cache.fingerprint == fingerprint {
            let age = now.timeIntervalSince(cache.cachedAt)
            if age >= 0, age < cacheTTL || !allowExecution { return cache.version }
        }
        guard allowExecution, let version = normalized(run(binary)) else { return nil }
        cache = (fingerprint, version, now)
        return version
    }

    static func resetCacheForTesting() { lock.lock(); cache = nil; lock.unlock() }

    private static func runVersionCommand(_ binary: URL) -> String? {
        (try? ClaudeCommandRunner.run(binary, arguments: ["--version"], timeout: 5)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `primary` accompanies the current usage request; `legacy` is used for its retry and for the profile.
    static func userAgents(version: String?) -> (primary: String, legacy: String) {
        let value = normalized(version) ?? fallback
        return ("claude-cli/\(value) (external, cli)", "claude-code/\(value)")
    }
}
