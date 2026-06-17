import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterService: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isConfigured = false

    private let updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSparkleConfiguration = feedURL?.isEmpty == false && publicKey?.isEmpty == false

        if hasSparkleConfiguration {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }

        super.init()

        isConfigured = hasSparkleConfiguration
        guard let updater = updaterController?.updater else {
            return
        }

        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyChecksForUpdates in
                self?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        guard let updater = updaterController?.updater else {
            NSWorkspace.shared.open(GitHubReleaseUpdateChecker.fallbackReleasePageURL)
            return
        }

        updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        guard let updater = updaterController?.updater else {
            automaticallyChecksForUpdates = isEnabled
            return
        }

        updater.automaticallyChecksForUpdates = isEnabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}
