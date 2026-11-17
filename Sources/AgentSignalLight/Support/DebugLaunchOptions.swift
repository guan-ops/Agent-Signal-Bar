import Foundation

enum DebugLaunchOptions {
    static var shouldOpenDebugWindow: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--debug-window") || arguments.contains("--ui-verify") {
            return true
        }

        let rawValue = ProcessInfo.processInfo.environment["AGENT_SIGNAL_LIGHT_DEBUG_WINDOW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["1", "true", "yes", "on"].contains(rawValue) {
            return true
        }

        return isStatusBarIconPersistentlyDisabled && !shouldForceStatusBarIconEnabled
    }

    static var shouldForceStatusBarIconEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--force-status-bar-icon") {
            return true
        }

        let rawValue = ProcessInfo.processInfo.environment["AGENT_SIGNAL_LIGHT_FORCE_STATUS_BAR_ICON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "yes", "on"].contains(rawValue)
    }

    static var statusItemHealthFileURL: URL? {
        healthFileURL(argument: "--status-item-health", environmentKey: "AGENT_SIGNAL_LIGHT_STATUS_ITEM_HEALTH_FILE")
    }

    /// Where `--ui-verify` reads whether the main window opened. Window titles from CGWindowList need
    /// Screen Recording permission, so the app reports its own window instead.
    static var debugWindowHealthFileURL: URL? {
        healthFileURL(argument: "--debug-window-health", environmentKey: "AGENT_SIGNAL_LIGHT_DEBUG_WINDOW_HEALTH_FILE")
    }

    static func healthFileURL(
        argument: String,
        environmentKey: String,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument),
           arguments.indices.contains(arguments.index(after: index)) {
            return URL(fileURLWithPath: arguments[arguments.index(after: index)])
        }

        guard let rawValue = environment[environmentKey],
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: rawValue)
    }

    private static var isStatusBarIconPersistentlyDisabled: Bool {
        UserDefaults.standard.object(forKey: "isStatusBarIconEnabled") as? Bool == false
    }
}
