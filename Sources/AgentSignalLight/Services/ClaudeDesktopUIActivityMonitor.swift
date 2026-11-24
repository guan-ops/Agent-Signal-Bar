import AgentSignalLightCore
import AppKit
import ApplicationServices
import Foundation

/// Optional, read-only fallback for cloud sessions that emit no local hooks.
/// Never reads AXValue (messages/composer text), performs actions, or requests trust.
enum ClaudeDesktopUIActivityMonitor {
    enum Observation: String, Sendable {
        case disabled, permissionRequired, notRunning, unavailable, notResponding, working
    }

    static func observe(enabled: Bool) -> Observation {
        guard enabled else { return .disabled }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let apps = NSWorkspace.shared.runningApplications.filter {
            ["com.anthropic.claudefordesktop", "com.anthropic.claude"].contains($0.bundleIdentifier ?? "")
        }
        guard !apps.isEmpty else { return .notRunning }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        var results: [Observation] = []
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            results.append(scan(root: root, expired: {
                ProcessInfo.processInfo.systemUptime >= deadline
            }, role: { attribute($0, kAXRoleAttribute) as? String }, label: { element in
                [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { name in
                    attribute(element, name) as? String
                }.first { !$0.isEmpty } ?? ""
            }, enabled: { attribute($0, kAXEnabledAttribute) as? Bool == true }, url: {
                (attribute($0, kAXURLAttribute) as? URL)?.host
            }, children: { element, limit in
                AXUIElementSetMessagingTimeout(element, 0.1)
                var count: CFIndex = 0
                let error = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                if error == .attributeUnsupported || error == .noValue { return [] }
                guard error == .success else { return nil }
                guard count > 0 else { return [] }
                guard count <= limit else { return nil }
                var values: CFArray?
                guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success else { return nil }
                return values as? [AXUIElement]
            }))
            if results.last == .working { return .working }
        }
        return results.contains(.notResponding) ? .notResponding : .unavailable
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Bounded breadth-first traversal. Labels are transient and never logged.
    static func scan<Node>(root: Node, maxNodes: Int = 1500,
        expired: () -> Bool, role: (Node) -> String?, label: (Node) -> String,
        enabled: (Node) -> Bool, url: (Node) -> String?,
        children: (Node, Int) -> [Node]?) -> Observation {
        var queue: [(Node, Int, Bool)] = [(root, 0, false)]
        var index = 0
        var sawClaudePage = false
        var incomplete = false
        while index < queue.count {
            guard index < maxNodes, !expired() else { return .unavailable }
            let (node, depth, insideClaudePage) = queue[index]
            index += 1
            guard let nodeRole = role(node) else { incomplete = true; continue }
            // Never inspect text, editable values, or message descendants.
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXImage"].contains(nodeRole) { continue }
            var inPage = insideClaudePage
            if nodeRole == "AXWebArea" {
                let host = url(node)?.lowercased()
                if host == "claude.ai" { inPage = true; sawClaudePage = true }
                else if host != nil { continue }
            }
            if nodeRole == "AXGroup" {
                let groupLabel = label(node).lowercased()
                if ["对话消息", "對話訊息", "conversation messages", "chat messages"].contains(groupLabel) { continue }
            }
            if nodeRole == "AXButton" {
                if inPage && enabled(node) && isStopResponseLabel(label(node)) { return .working }
                continue
            }
            guard depth < 24 else { incomplete = true; continue }
            guard !expired(), let descendants = children(node, maxNodes - queue.count) else {
                incomplete = true; continue
            }
            guard queue.count + descendants.count <= maxNodes else { return .unavailable }
            queue.append(contentsOf: descendants.map { ($0, depth + 1, inPage) })
        }
        return sawClaudePage && !incomplete ? .notResponding : .unavailable
    }

    static func isStopResponseLabel(_ label: String) -> Bool {
        ["停止回复", "停止回覆", "停止回应", "stop response", "stop generating", "stop responding"]
            .contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func applying(_ observation: Observation, to sessions: [SessionStatus], now: Date = Date()) -> [SessionStatus] {
        guard observation == .working else { return sessions }
        return sessions.filter { $0.sessionID != "platform-presence:claude-desktop" } + [
            SessionStatus(sessionID: "claude-desktop:ui", signal: .working, updatedAt: now,
                agent: "claude-desktop", lastEvent: "DesktopUI:Working")
        ]
    }
}
