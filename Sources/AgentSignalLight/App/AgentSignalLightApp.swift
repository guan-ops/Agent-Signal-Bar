import AgentSignalLightCore
import AppKit
import Darwin
import SwiftUI

enum SingleInstanceGuard {
    static func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                application.processIdentifier != currentProcessIdentifier && !application.isTerminated
            }

        guard let existingApplication else {
            return false
        }

        existingApplication.activate(options: [])
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DebugLaunchOptions.shouldOpenDebugWindow {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AgentSignalAppServices.statusBarController.showDebugWindow()
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        DispatchQueue.main.async {
            AgentSignalAppServices.statusBarController.showDebugWindow()
        }
        return true
    }
}

@MainActor
enum AgentSignalAppServices {
    static let model = MenuBarStatusModel()
    static let sparkleUpdater = SparkleUpdaterService()
    static let statusBarController = StatusBarController(model: model, updater: sparkleUpdater)
}

@MainActor
@main
struct AgentSignalLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: MenuBarStatusModel
    @StateObject private var sparkleUpdater: SparkleUpdaterService
    private let statusBarController: StatusBarController

    init() {
        if SingleInstanceGuard.activateExistingInstanceIfNeeded() {
            exit(0)
        }

        let sharedModel = AgentSignalAppServices.model
        _model = StateObject(wrappedValue: sharedModel)
        _sparkleUpdater = StateObject(wrappedValue: AgentSignalAppServices.sparkleUpdater)
        statusBarController = AgentSignalAppServices.statusBarController
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(model.text("设置...", "Settings...")) {
                    statusBarController.showDebugWindow()
                }
                .keyboardShortcut(",", modifiers: .command)

                Button(model.text("检查更新...", "Check for Updates...")) {
                    sparkleUpdater.checkForUpdates()
                }
                .disabled(sparkleUpdater.isConfigured && !sparkleUpdater.canCheckForUpdates)
            }
        }
    }
}
