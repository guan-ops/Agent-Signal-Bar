import Foundation

/// Local activity paths only. Selecting a directory does not select an account.
public enum CodexDataPaths {
    public static let preferenceKey = "codexActivityDataDirectory"

    public static func primaryRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   selectedPath: String? = nil) -> URL {
        for candidate in [selectedPath, environment["CODEX_HOME"]] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            let expanded = value == "~" ? home.path : value.hasPrefix("~/")
                ? home.appendingPathComponent(String(value.dropFirst(2))).path : value
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func activityRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     environment: [String: String] = ProcessInfo.processInfo.environment,
                                     selectedPath: String? = nil,
                                     fileManager: FileManager = .default) -> [(url: URL, agent: String?)] {
        var roots: [(URL, String?)] = [(primaryRoot(home: home, environment: environment, selectedPath: selectedPath)
            .appendingPathComponent("sessions"), nil)]
        // Keep Xcode's path even when it will be created after this app starts.
        roots.append((home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex/sessions"), "codex-xcode"))
        let products = (try? fileManager.contentsOfDirectory(at: home.appendingPathComponent("Library/Caches/JetBrains"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for product in products {
            let name = product.lastPathComponent.lowercased()
            roots.append((product.appendingPathComponent("aia/codex/sessions"),
                          name.contains("idea") || name.contains("intellij") ? "codex-idea" : "codex-jetbrains"))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.0.standardizedFileURL.path).inserted }
    }
}
