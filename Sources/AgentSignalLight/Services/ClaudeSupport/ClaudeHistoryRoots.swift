import Foundation

/// Directory layout informed by CodexBar's ClaudeConfigPaths/ClaudeDesktopProjectsLocator (MIT;
/// see Resources/ClaudeSupport-LICENSE.txt). Only local session metadata is discovered here.
enum ClaudeHistoryRoots {
    static func projects(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        // A profile path is one literal directory, including commas and spaces.
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return [URL(fileURLWithPath: configured, isDirectory: true).appendingPathComponent("projects", isDirectory: true)]
        }
        var roots = [home.appendingPathComponent(".config/claude/projects", isDirectory: true),
                     home.appendingPathComponent(".claude/projects", isDirectory: true)]
        let desktop = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let skipped: Set<String> = [".build", ".git", "build", "DerivedData", "node_modules", "outputs", "target", ".claude"]
        var queue = ["local-agent-mode-sessions", "claude-code-sessions"].map { (desktop.appendingPathComponent($0), 0) }
        var index = 0
        // Bound discovery independently of session-log scanning and never traverse symlinks.
        while index < queue.count, index < 4096 {
            let (directory, depth) = queue[index]
            index += 1
            let audit = directory.appendingPathComponent("audit.jsonl")
            if let values = try? audit.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink == false { roots.append(audit) }
            let projects = directory.appendingPathComponent(".claude/projects", isDirectory: true)
            if isDirectory(projects) { roots.append(projects) }
            guard depth < 4 else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.path < $1.path }) where !skipped.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink == false, queue.count < 4096 {
                    queue.append((child, depth + 1))
                }
            }
        }
        let swap = home.appendingPathComponent(".claude-swap-backup/sessions", isDirectory: true)
        let slots = (try? FileManager.default.contentsOfDirectory(at: swap,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for slot in slots.sorted(by: { $0.path < $1.path }) {
            let parts = slot.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let number = Int(parts[0]), number > 0 else { continue }
            let projects = slot.appendingPathComponent("projects", isDirectory: true)
            if isDirectory(projects) { roots.append(projects) }
        }
        var seen: Set<String> = []
        return roots.map(\.standardizedFileURL).filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
