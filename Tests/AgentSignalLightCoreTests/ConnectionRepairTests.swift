import Foundation
import XCTest
import AgentSignalLightCore
@testable import AgentSignalLight

final class ConnectionRepairTests: XCTestCase {
    func testPathPrecedenceAndTildeUseExplicitHome() throws {
        let home = URL(fileURLWithPath: "/private/tmp/path-fixture")
        XCTAssertEqual(CodexDataPaths.primaryRoot(home: home, environment: [:]).path, home.appendingPathComponent(".codex").path)
        XCTAssertEqual(CodexDataPaths.primaryRoot(home: home, environment: ["CODEX_HOME": " ~/custom " ]).path, home.appendingPathComponent("custom").path)
        XCTAssertEqual(CodexDataPaths.primaryRoot(home: home, environment: ["CODEX_HOME": "/env"], selectedPath: "/selected").path, "/selected")
    }

    func testEnvironmentAndSavedSelectionBothDiscoverLiveLogs() throws {
        for selected in [false, true] {
            let f = try RepairFixture(); defer { f.clean() }
            let directory = f.root.appendingPathComponent("custom/sessions")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let row = "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            try Data(row.utf8).write(to: directory.appendingPathComponent("rollout-test.jsonl"))
            let monitor = CodexDesktopActivityMonitor(environment: selected ? [:] : ["CODEX_HOME": directory.deletingLastPathComponent().path],
                selectedPath: selected ? directory.deletingLastPathComponent().path : nil,
                homeDirectory: f.root, vsCodeLogRootURL: f.root.appendingPathComponent("no-vscode"), replaysInitialHistory: true)
            let poll = monitor.pollResult()
            XCTAssertEqual(poll.activities.map(\.signal), [.thinking])
            XCTAssertEqual(poll.connection.recentFiles, 1)
            XCTAssertTrue(poll.connection.unreadable.isEmpty)
        }
    }

    func testConnectionHealthDistinguishesAbsentEmptyAndInvalidDirectories() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let directory = f.root.appendingPathComponent("sessions")
        let monitor = CodexDesktopActivityMonitor(homeDirectory: f.root, sessionRootURLs: [directory],
            vsCodeLogRootURL: f.root.appendingPathComponent("no-vscode"), fullScanInterval: 0)
        XCTAssertEqual(monitor.pollResult().connection.existingRoots, 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(monitor.pollResult().connection.existingRoots, 1)
        XCTAssertEqual(monitor.pollResult().connection.recentFiles, 0)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        XCTAssertFalse(monitor.pollResult().connection.unreadable.isEmpty)
    }

    func testNativeInstallationPreservesSettingsIsIdempotentAndRemovesOnlyOwnedHooks() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let original: [String: Any] = ["theme": "dark", "hooks": ["PreToolUse": [["matcher": "Bash", "note": "keep", "hooks": [["type": "command", "command": "/other/tool"]]]]]]
        try f.write(original, to: f.claude)
        let originalBytes = try Data(contentsOf: f.claude)
        let preview = try f.installer.run(target: "all", install: false)
        XCTAssertTrue(preview.contains("updated")); XCTAssertEqual(try Data(contentsOf: f.claude), originalBytes)
        let output = try f.installer.run(target: "all", install: true)
        XCTAssertTrue(output.contains("backup:"))
        let installed = try Data(contentsOf: f.claude)
        XCTAssertTrue(try f.installer.run(target: "all", install: true).contains("already configured"))
        XCTAssertEqual(try Data(contentsOf: f.claude), installed)
        let doc = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        let hooks = doc["hooks"] as! [String: Any]
        XCTAssertEqual(hooks.count, 26)
        XCTAssertNil(hooks["WorktreeCreate"])
        _ = try f.installer.run(target: "all", install: true, remove: true)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as? NSDictionary, original as NSDictionary)
    }

    func testNativeMigrationCleansLegacyWorktreeHooksAndPreservesForeignHooks() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let owned = ["type": "command", "command": "'/old/Agent Signal Bar/scripts/claude-code-signal-hook'"]
        let foreign = ["type": "command", "command": "/other/create-worktree"]
        try f.write(["hooks": ["WorktreeCreate": [["matcher": "", "note": "keep", "hooks": [owned, foreign]]],
                                 "PreToolUse": [["hooks": [owned]]]]], to: f.claude)
        _ = try f.installer.run(target: "claude", install: true)
        let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as! [String: Any])["hooks"] as! [String: Any]
        let worktree = (hooks["WorktreeCreate"] as! [[String: Any]])[0]
        XCTAssertEqual(worktree["note"] as? String, "keep")
        XCTAssertEqual(worktree["hooks"] as? [[String: String]], [foreign])
        XCTAssertEqual((hooks["PreToolUse"] as! [Any]).count, 1)
    }

    func testFailureOnSecondTargetRollsBackFirstAndKeepsBackups() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["original": true], to: f.codex)
        try f.write(["original": true], to: f.claude)
        let bytes = try Data(contentsOf: f.codex)
        XCTAssertThrowsError(try f.installer.run(target: "all", install: true, beforeCommit: { path in
            if path == f.claude { throw NativeHookInstallError.invalid("injected second-target failure") }
        }))
        XCTAssertEqual(try Data(contentsOf: f.codex), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.codex.deletingLastPathComponent().path).contains { $0.contains(".bak-") })
    }

    func testRepeatedRepairsKeepABoundedNumberOfBackups() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["original": true], to: f.claude)
        for _ in 0..<8 {
            _ = try f.installer.run(target: "claude", install: true)
            _ = try f.installer.run(target: "claude", install: true, remove: true)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: f.claude.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(f.claude.lastPathComponent + ".bak-") }
        XCTAssertEqual(backups.count, NativeHookInstaller.retainedBackups)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as? [String: Any])?["original"] as? Bool, true)
    }

    func testSymbolicLinkConfigIsRefusedWithAnExplanationAndLeftUntouched() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["original": true], to: f.claude)
        let target = f.root.appendingPathComponent("dotfiles-settings.json")
        try FileManager.default.moveItem(at: f.claude, to: target)
        try FileManager.default.createSymbolicLink(at: f.claude, withDestinationURL: target)
        let bytes = try Data(contentsOf: target)
        XCTAssertThrowsError(try f.installer.run(target: "claude", install: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.claude.path), target.path)
    }

    func testConcurrentEditIsNotOverwritten() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["before": true], to: f.codex)
        let concurrent = Data("{\"external\":true}".utf8)
        XCTAssertThrowsError(try f.installer.run(target: "codex", install: true, beforeCommit: { path in
            try concurrent.write(to: path)
        }))
        XCTAssertEqual(try Data(contentsOf: f.codex), concurrent)
    }

    func testMalformedSecondConfigDoesNotWriteFirst() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["hooks": "invalid"], to: f.claude)
        XCTAssertThrowsError(try f.installer.run(target: "all", install: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.codex.path))
    }

    func testSymbolicAndHardLinksAreRejected() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["preserve": true], to: f.claude)
        try FileManager.default.createDirectory(at: f.codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.codex, withDestinationURL: f.claude)
        XCTAssertThrowsError(try f.installer.run(target: "codex", install: true))
        try FileManager.default.removeItem(at: f.codex)
        try FileManager.default.linkItem(at: f.claude, to: f.codex)
        XCTAssertThrowsError(try f.installer.run(target: "codex", install: true))
    }

    func testPermissionsAndExtendedAttributesSurviveInstall() throws {
        let f = try RepairFixture(); defer { f.clean() }
        try f.write(["preserve": true], to: f.codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.codex.path)
        let write = Process(); write.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        write.arguments = ["-w", "com.agentsignal.fixture", "preserved", f.codex.path]
        try write.run(); write.waitUntilExit(); XCTAssertEqual(write.terminationStatus, 0)
        _ = try f.installer.run(target: "codex", install: true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.codex.path))[.posixPermissions] as? Int, 0o640)
        let read = Process(); read.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        read.arguments = ["-p", "com.agentsignal.fixture", f.codex.path]
        let pipe = Pipe(); read.standardOutput = pipe
        try read.run(); let value = pipe.fileHandleForReading.readDataToEndOfFile(); read.waitUntilExit()
        XCTAssertEqual(read.terminationStatus, 0)
        XCTAssertEqual(String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "preserved")
    }

    func testInstalledCommandRunsFromPathWithSpacesAndApostrophes() throws {
        let f = try RepairFixture(); defer { f.clean() }
        _ = try f.installer.run(target: "claude", install: true)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as! [String: Any]
        let hooks = doc["hooks"] as! [String: Any]
        let block = (hooks["PreToolUse"] as! [[String: Any]])[0]
        let command = (block["hooks"] as! [[String: Any]])[0]["command"] as! String
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testResourcePathAliasesDoNotReportInstalledHooksAsBroken() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let alias = f.root.appendingPathComponent("resource-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.resources)
        let aliasInstaller = NativeHookInstaller(resources: alias, home: f.root, environment: [:])
        _ = try aliasInstaller.run(target: "all", install: true)
        let bytes = try Data(contentsOf: f.claude)
        let preview = try f.installer.run(target: "all", install: false)
        XCTAssertEqual(preview.components(separatedBy: "already configured").count - 1, 2)
        XCTAssertEqual(try Data(contentsOf: f.claude), bytes)
    }

    func testPythonInstalledHooksAreRecognizedWithoutRewriting() throws {
        let f = try RepairFixture(); defer { f.clean() }
        // Python's shlex.quote leaves a plain path unquoted and escapes apostrophes as '"'"'.
        let plain = f.root.appendingPathComponent("PlainResources")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        for name in ["codex-signal-hook", "claude-code-signal-hook"] {
            try FileManager.default.copyItem(at: f.resources.appendingPathComponent("scripts/\(name)"),
                                             to: plain.appendingPathComponent("scripts/\(name)"))
        }
        func shlexQuote(_ path: String) -> String {
            path.contains(where: { $0 == " " || $0 == "'" }) ? "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" : path
        }
        for resources in [plain, f.resources] {
            let claudeCommand = shlexQuote(resources.appendingPathComponent("scripts/claude-code-signal-hook").path)
            let codexCommand = shlexQuote(resources.appendingPathComponent("scripts/codex-signal-hook").path)
            func block(_ command: String, _ event: String, _ matcher: String) -> [String: Any] {
                ["matcher": matcher, "hooks": [["type": "command", "command": command, "timeout": event == "PermissionRequest" ? 10 : 5]]]
            }
            var claudeHooks = Dictionary(uniqueKeysWithValues: NativeHookInstaller.claudeEvents.map { ($0, [block(claudeCommand, $0, "")]) })
            // A user's own hook registered after ours must not make the install look broken.
            claudeHooks["Stop"]?.append(["matcher": "", "hooks": [["type": "command", "command": "/usr/bin/true"]]])
            try f.write(["hooks": claudeHooks], to: f.claude)
            try f.write(["hooks": Dictionary(uniqueKeysWithValues: NativeHookInstaller.codexEvents.map {
                ($0, [block(codexCommand + " \($0)", $0, "*")]) })], to: f.codex)
            let claudeBytes = try Data(contentsOf: f.claude), codexBytes = try Data(contentsOf: f.codex)
            let installer = NativeHookInstaller(resources: resources, home: f.root, environment: [:])
            let preview = try installer.run(target: "all", install: false)
            XCTAssertEqual(preview.components(separatedBy: "already configured").count - 1, 2, preview)
            XCTAssertTrue(try installer.run(target: "all", install: true).contains("already configured"))
            XCTAssertEqual(try Data(contentsOf: f.claude), claudeBytes)
            XCTAssertEqual(try Data(contentsOf: f.codex), codexBytes)
        }
    }

    func testOwnedHooksThatDoNotRunForEveryToolOrEventAreRepaired() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let resources = f.installer.resources
        let claude = NativeHookInstaller.shellQuote(resources.appendingPathComponent("scripts/claude-code-signal-hook").path)
        let codex = NativeHookInstaller.shellQuote(resources.appendingPathComponent("scripts/codex-signal-hook").path)
        _ = try f.installer.run(target: "all", install: true)
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as! [String: Any]
        var hooks = settings["hooks"] as! [String: Any]
        hooks["PreToolUse"] = [["matcher": "Bash", "hooks": [["type": "command", "command": claude]]]]
        hooks["Stop"] = [["matcher": "", "hooks": [["type": "command", "command": claude]]],
                         ["matcher": "", "hooks": [["type": "command", "command": claude]]]]
        settings["hooks"] = hooks
        try f.write(settings, to: f.claude)
        var codexSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: f.codex)) as! [String: Any]
        var codexHooks = codexSettings["hooks"] as! [String: Any]
        codexHooks["Stop"] = [["matcher": "*", "hooks": [["type": "command", "command": codex]]]]
        codexSettings["hooks"] = codexHooks
        try f.write(codexSettings, to: f.codex)

        let preview = try f.installer.run(target: "all", install: false)
        XCTAssertFalse(preview.contains("already configured"), preview)
        _ = try f.installer.run(target: "all", install: true)
        let repaired = (try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as! [String: Any])["hooks"] as! [String: Any]
        let preToolUse = repaired["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(preToolUse.count, 1)
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "")
        XCTAssertEqual((repaired["Stop"] as! [Any]).count, 1)
        let codexStop = ((try JSONSerialization.jsonObject(with: Data(contentsOf: f.codex)) as! [String: Any])["hooks"]
            as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual((codexStop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, codex + " Stop")
        XCTAssertEqual(try f.installer.run(target: "all", install: false).components(separatedBy: "already configured").count - 1, 2)
    }

    func testHooksAreNotInstalledFromATranslocatedApp() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let translocated = f.root.appendingPathComponent("AppTranslocation/0A1B2C/d/AgentSignalLight.app/Contents/Resources")
        try FileManager.default.createDirectory(at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.resources, to: translocated)
        let installer = NativeHookInstaller(resources: translocated, home: f.root, environment: [:])
        XCTAssertTrue(NativeHookInstaller.isTemporaryAppLocation(translocated))
        XCTAssertFalse(NativeHookInstaller.isTemporaryAppLocation(f.resources))
        for install in [true, false] {
            XCTAssertThrowsError(try installer.run(target: "all", install: install)) { error in
                XCTAssertEqual(error.localizedDescription, NativeHookInstaller.temporaryLocationMessage)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.codex.path))
        // Removing hooks left by an earlier install stays possible from anywhere.
        _ = try f.installer.run(target: "claude", install: true)
        _ = try installer.run(target: "claude", install: true, remove: true)
        let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: f.claude)) as? [String: Any])?["hooks"] as? [String: Any]
        XCTAssertTrue(hooks?.isEmpty ?? true)
    }

    func testHooksAreNotInstalledFromAMountedDiskImage() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let source = f.root.appendingPathComponent("image-source/AgentSignalLight.app/Contents")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.resources, to: source.appendingPathComponent("Resources"))
        let image = f.root.appendingPathComponent("AgentSignalBar.dmg")
        func hdiutil(_ arguments: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeHookInstallError.invalid("hdiutil \(arguments[0]) failed") }
            return output
        }
        _ = try hdiutil(["create", "-quiet", "-srcfolder", f.root.appendingPathComponent("image-source").path,
                         "-volname", "AgentSignalBar", "-format", "UDZO", image.path])
        let mountRoot = f.root.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attached = try hdiutil(["attach", "-nobrowse", "-readonly", "-mountrandom", mountRoot.path, image.path])
        let mount = try XCTUnwrap(attached.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }.first { $0.hasPrefix(mountRoot.path) || $0.hasPrefix("/private" + mountRoot.path) || $0.hasPrefix(mountRoot.resolvingSymlinksInPath().path) })
        defer { _ = try? hdiutil(["detach", "-quiet", "-force", mount]) }
        let resources = URL(fileURLWithPath: mount).appendingPathComponent("AgentSignalLight.app/Contents/Resources")
        XCTAssertTrue(NativeHookInstaller.isTemporaryAppLocation(resources))
        XCTAssertThrowsError(try NativeHookInstaller(resources: resources, home: f.root, environment: [:])
            .run(target: "claude", install: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.claude.path))
    }

    func testShellWordsHonorQuotingAndRejectUnbalancedInput() {
        XCTAssertEqual(NativeHookInstaller.shellWords(#"'/a b/hook' Stop"#), ["/a b/hook", "Stop"])
        XCTAssertEqual(NativeHookInstaller.shellWords(#"'/a'"'"'s/hook'"#), ["/a's/hook"])
        XCTAssertEqual(NativeHookInstaller.shellWords(#"/a\ b/hook   x"#), ["/a b/hook", "x"])
        XCTAssertEqual(NativeHookInstaller.shellWords(#"'' x"#), ["", "x"])
        XCTAssertNil(NativeHookInstaller.shellWords(#"'/a/hook"#))
    }

    func testCustomCodexDirectoryIsUsedForHookInstallation() throws {
        let f = try RepairFixture(); defer { f.clean() }
        let custom = f.root.appendingPathComponent("custom")
        let installer = NativeHookInstaller(resources: f.resources, home: f.root, environment: [:], selectedCodexPath: custom.path)
        _ = try installer.run(target: "codex", install: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.appendingPathComponent("hooks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.codex.path))
    }
}

private struct RepairFixture {
    let root: URL
    var resources: URL { root.appendingPathComponent("App's Resources") }
    var codex: URL { root.appendingPathComponent(".codex/hooks.json") }
    var claude: URL { root.appendingPathComponent(".claude/settings.json") }
    var installer: NativeHookInstaller { .init(resources: resources, home: root, environment: [:]) }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/connection-repair-\(UUID())")
        let scripts = resources.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["codex-signal-hook", "claude-code-signal-hook"] {
            let file = scripts.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }
    func write(_ data: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(to: url)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
