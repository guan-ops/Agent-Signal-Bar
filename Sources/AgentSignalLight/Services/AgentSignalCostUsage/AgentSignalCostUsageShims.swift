import Foundation

// Minimal shims required by the imported cost-usage scanner. Keep this file small
// so the scanner can be updated without dragging unrelated menu, cookie, or
// account code into this app.

enum UsageProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case openai
    case azureopenai
    case claude
    case cursor
    case opencode
    case opencodego
    case alibaba
    case alibabatokenplan
    case factory
    case gemini
    case antigravity
    case copilot
    case devin
    case zai
    case minimax
    case manus
    case kimi
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case kimik2
    case moonshot
    case amp
    case t3chat
    case ollama
    case synthetic
    case warp
    case openrouter
    case elevenlabs
    case windsurf
    case zed
    case perplexity
    case mimo
    case doubao
    case abacus
    case mistral
    case deepseek
    case codebuff
    case crof
    case venice
    case commandcode
    case stepfun
    case bedrock
    case grok
    case groq
    case llmproxy
    case litellm
    case deepgram
    case poe
    case chutes
}

enum LogCategories {
    static let tokenCost = "token-cost"
}

enum AgentSignalCostUsageLog {
    static func logger(_ category: String) -> AgentSignalCostUsageLogger {
        AgentSignalCostUsageLogger(category: category)
    }
}

struct AgentSignalCostUsageLogger: Sendable {
    let category: String

    func warning(_ message: String, metadata: [String: String] = [:]) {
        #if DEBUG
        debugPrint("[\(category)] warning:", message, metadata)
        #endif
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        #if DEBUG
        debugPrint("[\(category)] info:", message, metadata)
        #endif
    }

    func error(_ message: String, metadata: [String: String] = [:]) {
        #if DEBUG
        debugPrint("[\(category)] error:", message, metadata)
        #endif
    }
}

enum CodexParserHash {
    static let value = "800a06dead603ea7"
}
