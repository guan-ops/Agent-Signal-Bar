import Foundation

struct GitHubUpdateCheckResult: Equatable, Sendable {
    let currentVersion: String
    let latestVersion: String
    let releasePageURL: URL
    let downloadURL: URL?
    let isUpdateAvailable: Bool
}

struct GitHubReleaseUpdateChecker: Sendable {
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/guan-ops/Agent-Signal-Bar/releases/latest")!
    static let fallbackReleasePageURL = URL(string: "https://github.com/guan-ops/Agent-Signal-Bar/releases/latest")!

    var session: URLSessionProtocol = URLSession.shared
    var apiURL: URL = Self.latestReleaseAPIURL
    var releasePageURL: URL = Self.fallbackReleasePageURL

    func check(currentVersion: String) async throws -> GitHubUpdateCheckResult {
        do {
            return try await checkAPI(currentVersion: currentVersion)
        } catch {
            return try await checkReleasePage(currentVersion: currentVersion)
        }
    }

    private func checkAPI(currentVersion: String) async throws -> GitHubUpdateCheckResult {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Agent-Signal-Bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubUpdateCheckError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubUpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let release = try Self.decodeLatestRelease(from: data)
        let latestVersion = Self.displayVersion(from: release.tagName)
        let comparison = Self.compareVersions(latestVersion, currentVersion)

        return GitHubUpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releasePageURL: release.htmlURL,
            downloadURL: release.preferredDownloadURL,
            isUpdateAvailable: comparison == .orderedDescending
        )
    }

    private func checkReleasePage(currentVersion: String) async throws -> GitHubUpdateCheckResult {
        var request = URLRequest(url: releasePageURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Agent-Signal-Bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubUpdateCheckError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubUpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let finalURL = httpResponse.url ?? releasePageURL
        let tagName = Self.tagName(fromReleasePageURL: finalURL)
            ?? Self.tagName(fromReleasePageHTML: data)
        guard let tagName else {
            throw GitHubUpdateCheckError.decodingFailed
        }

        let latestVersion = Self.displayVersion(from: tagName)
        let comparison = Self.compareVersions(latestVersion, currentVersion)
        let releasePageURL = URL(string: "https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/\(tagName)") ?? finalURL

        return GitHubUpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releasePageURL: releasePageURL,
            downloadURL: nil,
            isUpdateAvailable: comparison == .orderedDescending
        )
    }

    static func decodeLatestRelease(from data: Data) throws -> GitHubLatestRelease {
        do {
            return try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
        } catch {
            throw GitHubUpdateCheckError.decodingFailed
        }
    }

    static func displayVersion(from tagName: String) -> String {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0

            if leftValue > rightValue {
                return .orderedDescending
            }

            if leftValue < rightValue {
                return .orderedAscending
            }
        }

        return .orderedSame
    }

    static func tagName(fromReleasePageURL url: URL) -> String? {
        let pathComponents = url.pathComponents
        guard let releasesIndex = pathComponents.firstIndex(of: "releases") else {
            return nil
        }
        let tagIndex = releasesIndex + 1
        let valueIndex = releasesIndex + 2
        guard pathComponents.indices.contains(tagIndex),
              pathComponents.indices.contains(valueIndex),
              pathComponents[tagIndex] == "tag"
        else {
            return nil
        }
        return pathComponents[valueIndex]
    }

    static func tagName(fromReleasePageHTML data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pattern = #"/guan-ops/Agent-Signal-Bar/releases/tag/([^"?#/]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let tagRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return String(html[tagRange])
    }

    private static func versionComponents(_ version: String) -> [Int] {
        let trimmed = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let numericPrefix = withoutPrefix.prefix { character in
            character.isNumber || character == "."
        }

        return numericPrefix
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

enum GitHubUpdateCheckError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .httpStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .decodingFailed:
            return "GitHub release data could not be read."
        }
    }
}

struct GitHubLatestRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

extension GitHubLatestRelease {
    var preferredDownloadURL: URL? {
        preferredMacOSAsset?.browserDownloadURL
    }

    private var preferredMacOSAsset: Asset? {
        assets.first { $0.name.hasPrefix("AgentSignalBar-v") && $0.name.contains("-macos-universal") && $0.name.hasSuffix(".dmg") }
            ?? assets.first { $0.name == "AgentSignalBar.dmg" }
            ?? assets.first { $0.name == "AgentSignalLight-local.dmg" }
            ?? assets.first { $0.name.hasSuffix(".dmg") }
            ?? assets.first { $0.name.hasPrefix("AgentSignalBar-v") && $0.name.contains("-macos-universal") && $0.name.hasSuffix(".zip") }
            ?? assets.first { $0.name.hasSuffix(".zip") }
    }
}

protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
