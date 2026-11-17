import Darwin
import Foundation

public enum NativeHookInstallError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Native config installation shared by the app and its bundled CLI.
/// All targets are prepared before any writes. Existing unrelated settings survive.
public struct NativeHookInstaller: Sendable {
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]
    public static let claudeEvents = ["ConfigChange", "CwdChanged", "Elicitation", "ElicitationResult", "FileChanged", "InstructionsLoaded", "SessionStart", "TaskCreated", "TaskCompleted", "TeammateIdle", "UserPromptExpansion", "UserPromptSubmit", "PreToolUse", "PostToolBatch", "PostToolUse", "PostToolUseFailure", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SessionEnd"]
    private static let lock = NSLock()
    public let resources: URL
    public let home: URL
    public let codexRoot: URL
    public let claudeRoot: URL

    public init(resources: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment, selectedCodexPath: String? = nil) {
        self.resources = resources.standardizedFileURL.resolvingSymlinksInPath()
        self.home = home
        self.codexRoot = CodexDataPaths.primaryRoot(home: home, environment: environment, selectedPath: selectedCodexPath)
        let claude = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.claudeRoot = claude.isEmpty ? home.appendingPathComponent(".claude")
            : URL(fileURLWithPath: claude.hasPrefix("~/") ? home.appendingPathComponent(String(claude.dropFirst(2))).path : claude)
    }

    public func run(target: String, install: Bool, remove: Bool = false,
                    projectRoot: URL? = nil, beforeCommit: ((URL) throws -> Void)? = nil) throws -> String {
        guard ["all", "codex", "claude"].contains(target) else { throw failure("Unknown hook target: \(target)") }
        // Hooks must name a path that still exists after the app quits. Removal only needs
        // to recognise owned commands, so it stays available from anywhere.
        if !remove, Self.isTemporaryAppLocation(resources) { throw failure(Self.temporaryLocationMessage) }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let specs = specifications(target: target, projectRoot: projectRoot)
        let plans = try specs.map { try prepare($0, remove: remove) }
        guard install else { return plans.map { description($0, installed: false, backup: nil) }.joined(separator: "\n") }
        var applied: [(plan: Plan, written: Snapshot, backup: URL?)] = []
        var messages: [String] = []
        do {
            for plan in plans {
                guard plan.changed else { messages.append(description(plan, installed: true, backup: nil)); continue }
                try FileManager.default.createDirectory(at: plan.spec.path.deletingLastPathComponent(), withIntermediateDirectories: true)
                var backup: URL?
                if plan.original != nil {
                    let url = plan.spec.path.appendingPathExtension("bak-\(UUID().uuidString)")
                    try requireUnchanged(plan.spec.path, plan.original)
                    try FileManager.default.copyItem(at: plan.spec.path, to: url)
                    guard try read(url)?.data == plan.original?.data else { throw failure("Backup changed during creation") }
                    backup = url
                }
                try beforeCommit?(plan.spec.path)
                let written = try replace(plan.spec.path, data: plan.data, expected: plan.original, metadataSource: backup)
                applied.append((plan, written, backup))
                messages.append(description(plan, installed: true, backup: backup))
            }
        } catch {
            var rollbackErrors: [String] = []
            for item in applied.reversed() {
                do {
                    if let original = item.plan.original {
                        _ = try replace(item.plan.spec.path, data: original.data, expected: item.written, metadataSource: item.backup)
                    } else {
                        try requireUnchanged(item.plan.spec.path, item.written)
                        try FileManager.default.removeItem(at: item.plan.spec.path)
                    }
                } catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty { throw failure("\(error.localizedDescription)\nRollback needs attention: \(rollbackErrors.joined(separator: "; "))") }
            throw error
        }
        for item in applied where item.backup != nil { pruneBackups(of: item.plan.spec.path) }
        return messages.joined(separator: "\n")
    }

    public static let temporaryLocationMessage =
        "Agent Signal Bar 正在临时位置运行（磁盘映像或未移动的下载），这里安装的 Hook 会在退出后失效。请先把 app 拖到「应用程序」文件夹，从那里打开后再安装 Hook。"
        + " / Agent Signal Bar is running from a temporary location (a disk image or an unmoved download); hooks installed here stop working once it quits. Move the app to the Applications folder, open it from there, then install hooks."

    /// Gatekeeper App Translocation runs quarantined apps from a random path that is removed
    /// when they quit, and a mounted disk image disappears on eject. An app on a writable
    /// volume, including an external drive, is a permanent location.
    public static func isTemporaryAppLocation(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains("AppTranslocation") { return true }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    public static let retainedBackups = 5
    /// Best effort: keep the newest owned `.bak-*` siblings so repeated repairs do not
    /// accumulate copies of the user's settings. Never follows links or touches other files.
    private func pruneBackups(of config: URL) {
        let directory = config.deletingLastPathComponent(), prefix = config.lastPathComponent + ".bak-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names.filter { $0.hasPrefix(prefix) }.compactMap { name -> (URL, Int64)? in
            let url = directory.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return nil }
            // Copies keep the config's modification time; the inode change time is when the backup was made.
            return (url, Int64(st.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_ctimespec.tv_nsec))
        }.sorted { $0.1 > $1.1 }
        for (url, _) in backups.dropFirst(Self.retainedBackups) { try? FileManager.default.removeItem(at: url) }
    }

    private struct Spec {
        let name: String; let path: URL; let wrapper: URL; let events: [String]; let codex: Bool
    }
    private struct Plan {
        let spec: Spec; let original: Snapshot?; let data: Data; let changed: Bool
        let added: [String]; let removed: [String]
    }
    private struct Snapshot: Equatable {
        let data: Data; let inode: UInt64; let device: Int32; let mode: UInt16
        let modified: Int64; let changed: Int64
    }
    private func specifications(target: String, projectRoot: URL?) -> [Spec] {
        var specs: [Spec] = []
        if target != "claude" {
            specs.append(Spec(name: projectRoot == nil ? "Codex User" : "Codex Project",
                path: (projectRoot?.appendingPathComponent(".codex") ?? codexRoot).appendingPathComponent("hooks.json"),
                wrapper: resources.appendingPathComponent("scripts/codex-signal-hook"), events: Self.codexEvents, codex: true))
        }
        if target != "codex" {
            specs.append(Spec(name: "Claude Code", path: claudeRoot.appendingPathComponent("settings.json"),
                wrapper: resources.appendingPathComponent("scripts/claude-code-signal-hook"), events: Self.claudeEvents, codex: false))
        }
        return specs
    }

    private func prepare(_ spec: Spec, remove: Bool) throws -> Plan {
        if !remove, !FileManager.default.isExecutableFile(atPath: spec.wrapper.path) {
            throw failure("Bundled hook is missing or not executable: \(spec.wrapper.path)")
        }
        let original = try read(spec.path)
        let parsed: Any = try original.map { try JSONSerialization.jsonObject(with: $0.data) } ?? [String: Any]()
        guard var document = parsed as? [String: Any] else { throw failure("Config must be a JSON object: \(spec.path.path)") }
        guard var hooks = (document["hooks"] ?? [String: Any]()) as? [String: Any] else { throw failure("hooks must be an object: \(spec.path.path)") }
        var added: [String] = []; var removed: [String] = []; var present: Set<String> = []
        // Remove only owned commands, including obsolete WorktreeCreate/Remove and stale paths.
        // An existing registration that already runs this wrapper for every tool stays where
        // it is (whatever its quoting, e.g. from the Python installer), so a working install is
        // neither reordered nor reported as broken. Missing events get one canonical block.
        let before = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        for event in Array(hooks.keys) {
            guard let blocks = hooks[event] as? [Any] else { throw failure("hooks.\(event) must be an array") }
            let wanted = !remove && spec.events.contains(event)
            var filtered: [Any] = []
            for value in blocks {
                guard var block = value as? [String: Any], let items = block["hooks"] as? [Any] else { filtered.append(value); continue }
                let matchesAllTools = ["", "*"].contains(block["matcher"] as? String ?? "")
                let kept = items.filter { value in
                    guard let item = value as? [String: Any], let command = item["command"] as? String,
                          owns(command, wrapper: spec.wrapper) else { return true }
                    if wanted, matchesAllTools, !present.contains(event), isCurrent(command, spec: spec, event: event) {
                        present.insert(event)
                        return true
                    }
                    return false
                }
                if kept.count != items.count {
                    if !removed.contains(event) { removed.append(event) }
                    if !kept.isEmpty { block["hooks"] = kept; filtered.append(block) }
                } else { filtered.append(value) }
            }
            if filtered.isEmpty && removed.contains(event) { hooks.removeValue(forKey: event) }
            else { hooks[event] = filtered }
        }
        if !remove {
            for event in spec.events where !present.contains(event) {
                var blocks = hooks[event] as? [Any] ?? []
                let command = Self.shellQuote(spec.wrapper.path) + (spec.codex ? " \(event)" : "")
                blocks.append(["matcher": spec.codex ? "*" : "", "hooks": [["type": "command", "command": command,
                    "timeout": event == "PermissionRequest" ? 10 : 5]]])
                hooks[event] = blocks; added.append(event)
            }
        }
        if !hooks.isEmpty || document["hooks"] != nil { document["hooks"] = hooks }
        let after = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let changed = before != after
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
        return Plan(spec: spec, original: original, data: data, changed: changed,
                    added: changed && !remove ? added : [], removed: changed ? removed.sorted() : [])
    }

    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Splits a command into shell words without executing any shell text; nil when quoting is unbalanced.
    public static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []; var token = ""; var inWord = false
        var quote: Character?; var escape = false
        for char in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escape { token.append(char); escape = false; inWord = true; continue }
            if char == "\\", quote != "'" { escape = true; continue }
            if let q = quote { if char == q { quote = nil } else { token.append(char) }; continue }
            if char == "'" || char == "\"" { quote = char; inWord = true; continue }
            if char.isWhitespace {
                if inWord { words.append(token); token = ""; inWord = false }
                continue
            }
            token.append(char); inWord = true
        }
        guard quote == nil, !escape else { return nil }
        if inWord { words.append(token) }
        return words
    }

    /// True when the command runs exactly this wrapper with the arguments this installer would write.
    private func isCurrent(_ command: String, spec: Spec, event: String) -> Bool {
        guard let words = Self.shellWords(command), let executable = words.first,
              Array(words.dropFirst()) == (spec.codex ? [event] : []) else { return false }
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return canonical(URL(fileURLWithPath: executable)) == canonical(spec.wrapper)
    }

    private func owns(_ command: String, wrapper: URL) -> Bool {
        // Parse just the executable shell word, so trailing text never hides an owned registration.
        var token = ""; var quote: Character?; var escape = false
        for char in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escape { token.append(char); escape = false; continue }
            if char == "\\", quote != "'" { escape = true; continue }
            if let q = quote { if char == q { quote = nil } else { token.append(char) }; continue }
            if char == "'" || char == "\"" { quote = char; continue }
            if char.isWhitespace { break }; token.append(char)
        }
        guard quote == nil, !escape else { return false }
        let url = URL(fileURLWithPath: token)
        guard url.lastPathComponent == wrapper.lastPathComponent else { return false }
        return url.standardizedFileURL == wrapper.standardizedFileURL || url.deletingLastPathComponent().lastPathComponent == "scripts"
            || ["agent-signal", "agentsignal", "agent signal", "ai agent状态栏红绿灯"].contains { token.lowercased().contains($0) }
    }
    private func description(_ plan: Plan, installed: Bool, backup: URL?) -> String {
        var lines = ["[\(installed ? "installed" : "dry-run")] \(plan.spec.name): \(plan.changed ? "updated" : "already configured")",
                     "  file: \(plan.spec.path.path)", "  wrapper: \(plan.spec.wrapper.path)"]
        if !plan.added.isEmpty { lines.append("  add events: \(plan.added.joined(separator: ", "))") }
        if !plan.removed.isEmpty { lines.append("  remove events: \(plan.removed.joined(separator: ", "))") }
        if let backup { lines.append("  backup: \(backup.path)") }
        return lines.joined(separator: "\n")
    }
    private func read(_ url: URL) throws -> Snapshot? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            // Deliberate, as in script/install_hooks.py: a linked config is never written through.
            if errno == ELOOP { throw failure("Config is a symbolic link, which is not modified for safety; edit the link target's hooks manually: \(url.path)") }
            throw failure("Cannot safely open config: \(url.path)")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == getuid(), st.st_flags == 0 else {
            throw failure("Config must be an owned, regular, single-link file: \(url.path)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        var after = stat(); guard fstat(fd, &after) == 0,
            st.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            st.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, st.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw failure("Config changed while reading: \(url.path)") }
        return Snapshot(data: data, inode: UInt64(st.st_ino), device: st.st_dev, mode: st.st_mode,
            modified: Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec),
            changed: Int64(st.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_ctimespec.tv_nsec))
    }
    private func requireUnchanged(_ url: URL, _ expected: Snapshot?) throws {
        guard try read(url) == expected else { throw failure("Config changed concurrently; retry: \(url.path)") }
    }
    private func replace(_ url: URL, data: Data, expected: Snapshot?, metadataSource: URL?) throws -> Snapshot {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".agent-signal-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        if let metadataSource { try FileManager.default.copyItem(at: metadataSource, to: temp) }
        else { guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("Cannot create config staging file") } }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.truncate(atOffset: 0); try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try requireUnchanged(url, expected)
        let result = expected == nil ? link(temp.path, url.path) : rename(temp.path, url.path)
        guard result == 0 else { throw failure("Cannot commit config (errno \(errno)): \(url.path)") }
        if expected == nil { try FileManager.default.removeItem(at: temp) }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY)
        if dir >= 0 { _ = fsync(dir); close(dir) }
        guard let written = try read(url), written.data == data else { throw failure("Config changed after commit: \(url.path)") }
        return written
    }
    private func failure(_ message: String) -> NativeHookInstallError { .invalid(message) }
}
