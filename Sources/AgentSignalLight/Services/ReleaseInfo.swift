import Foundation

struct ReleaseInfo: Equatable, Sendable {
    static var fallbackVersion: String { VersionConfiguration.current.version }
    static var fallbackBuild: String { VersionConfiguration.current.build }

    let version: String
    let build: String
    let signingMode: String
    let notarizationReady: Bool
    let manifestURL: URL?
    let releaseInfoURL: URL?

    var versionLine: String {
        "Version \(version) (\(build))"
    }

    var releaseLine: String {
        let signing = signingMode == "developer_id" ? "Developer ID" : "Local"
        let notarization = notarizationReady ? "notary ready" : "not notarized"
        return "\(signing) / \(notarization)"
    }

    var clipboardText: String {
        var lines = [
            "Agent Signal Bar \(versionLine)",
            "Release: \(releaseLine)"
        ]
        if let manifestURL {
            lines.append("Manifest: \(manifestURL.path)")
        } else if let releaseInfoURL {
            lines.append("Release info: \(releaseInfoURL.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func current() -> ReleaseInfo {
        let info = appBundleInfoDictionary() ?? Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? fallbackVersion
        let build = info["CFBundleVersion"] as? String ?? fallbackBuild
        let manifestURL = findManifestURL()
        let releaseInfoURL = findReleaseInfoURL()
        let manifest = manifestURL.flatMap { ReleaseMetadata(url: $0) }
        let releaseInfo = releaseInfoURL.flatMap { ReleaseMetadata(url: $0) }
        let metadata = releaseInfo ?? manifest

        return ReleaseInfo(
            version: metadata?.version ?? version,
            build: metadata?.build ?? build,
            signingMode: metadata?.signingMode ?? "ad_hoc",
            notarizationReady: metadata?.notarizationReady ?? false,
            manifestURL: manifestURL,
            releaseInfoURL: releaseInfoURL
        )
    }

    var releaseFileURL: URL? {
        releaseInfoURL ?? manifestURL
    }

    private static func findManifestURL() -> URL? {
        let fileName = "AgentSignalLight-release-manifest.json"
        let bundleURL = appBundleURL ?? Bundle.main.bundleURL.standardizedFileURL
        let distParent = bundleURL.deletingLastPathComponent()
        if distParent.lastPathComponent == "dist" {
            let manifestURL = distParent.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }

            let rootManifestURL = distParent.deletingLastPathComponent()
                .appendingPathComponent("dist")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: rootManifestURL.path) {
                return rootManifestURL
            }
        }

        if let resourceURL = appResourceURL ?? Bundle.main.resourceURL?.standardizedFileURL {
            let manifestURL = resourceURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
            .appendingPathComponent("dist")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        return nil
    }

    private static func findReleaseInfoURL() -> URL? {
        let fileName = "AgentSignalLight-release-info.json"

        if let resourceURL = appResourceURL ?? Bundle.main.resourceURL?.standardizedFileURL {
            let releaseInfoURL = resourceURL.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: releaseInfoURL.path) {
                return releaseInfoURL
            }
        }

        let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
            .appendingPathComponent("dist")
            .appendingPathComponent("AgentSignalLight.app")
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        return nil
    }

    private static var appBundleURL: URL? {
        let mainBundleURL = Bundle.main.bundleURL.standardizedFileURL
        if mainBundleURL.pathExtension == "app" {
            return mainBundleURL
        }

        let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL
        let components = executableURL.pathComponents

        guard let contentsIndex = components.lastIndex(of: "Contents"), contentsIndex > 0 else {
            return nil
        }

        let appComponents = Array(components[..<contentsIndex])
        guard let appURL = NSURL.fileURL(withPathComponents: appComponents)?.standardizedFileURL,
              appURL.pathExtension == "app" else {
            return nil
        }

        return appURL
    }

    fileprivate static var appResourceURL: URL? {
        appBundleURL?.appendingPathComponent("Contents").appendingPathComponent("Resources")
    }

    private static func appBundleInfoDictionary() -> [String: Any]? {
        guard let appBundleURL else { return nil }
        let infoURL = appBundleURL.appendingPathComponent("Contents").appendingPathComponent("Info.plist")

        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return plist
    }
}

private struct VersionConfiguration {
    let version: String
    let build: String

    static var current: VersionConfiguration {
        candidateURLs()
            .lazy
            .compactMap { VersionConfiguration(url: $0) }
            .first ?? VersionConfiguration(version: "0.0.0", build: "0")
    }

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    init?(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let values = contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }

        guard let version = values["VERSION"],
              let build = values["BUILD"],
              Self.isValidVersion(version),
              Self.isValidBuild(build) else {
            return nil
        }

        self.version = version
        self.build = build
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let resourceFileName = "AgentSignalLight-version.env"

        if let resourceURL = ReleaseInfo.appResourceURL ?? Bundle.main.resourceURL?.standardizedFileURL {
            urls.append(resourceURL.appendingPathComponent(resourceFileName))
        }

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        urls.append(currentDirectoryURL.appendingPathComponent("VERSION"))

        return urls
    }

    private static func isValidVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func isValidBuild(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
    }
}

private struct ReleaseMetadata: Decodable {
    let version: String
    let build: String
    let signing: Signing
    let notarization: Notarization

    var signingMode: String { signing.mode }
    var notarizationReady: Bool { notarization.readyToSubmit }

    init?(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            self = try JSONDecoder().decode(ReleaseMetadata.self, from: data)
        } catch {
            return nil
        }
    }

    struct Signing: Decodable {
        let mode: String
    }

    struct Notarization: Decodable {
        let readyToSubmit: Bool

        private enum CodingKeys: String, CodingKey {
            case readyToSubmit = "ready_to_submit"
        }
    }
}
