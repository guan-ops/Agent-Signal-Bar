import Foundation

/// AIMonitor in-scope desktop clients. Identify by bundle ID, never display name alone.
public enum MonitoredClientApp: String, CaseIterable, Sendable {
    /// Consumer ChatGPT preferred; on many Macs ChatGPT.app is actually Codex (`com.openai.codex`).
    case chatgptDesktop
    case claudeDesktop
    case grokBot

    /// Ordered preference: first match wins.
    public var preferredBundleIdentifiers: [String] {
        switch self {
        case .chatgptDesktop:
            // Prefer true consumer ChatGPT when present; fall back to Codex-branded ChatGPT.app (verified).
            return ["com.openai.chat", "com.openai.codex"]
        case .claudeDesktop:
            return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .grokBot:
            return ["com.anysphere.sand"]
        }
    }

    public var displayName: String {
        switch self {
        case .chatgptDesktop:
            return "ChatGPT"
        case .claudeDesktop:
            return "Claude"
        case .grokBot:
            return "Grok Bot"
        }
    }
}
