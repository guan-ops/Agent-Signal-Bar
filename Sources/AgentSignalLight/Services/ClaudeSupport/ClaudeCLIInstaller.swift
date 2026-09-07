import Foundation

enum ClaudeCLIInstaller {
    // Official native installer; installs into the user's ~/.local/bin without sudo.
    static func install(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        download: @Sendable () async throws -> Data = downloadInstaller
    ) async throws -> URL {
        let binary = homeDirectory.appendingPathComponent(".local/bin/claude")
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        let data = try await download()
        guard data.count <= 1_048_576, data.starts(with: Data("#!/bin/bash".utf8)) else {
            throw ClaudeSupportError.invalidResponse
        }
        // Let the installer finish its file transaction; do not cancel midway through an install.
        return try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-install-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("install.sh")
            try data.write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
            _ = try ClaudeCommandRunner.run(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, "stable"], timeout: 600)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ClaudeSupportError.missingCLI }
            _ = try ClaudeCommandRunner.run(binary, arguments: ["--version"], timeout: 15)
            return binary
        }.value
    }

    private static func downloadInstaller() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: ClaudeInstallerRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://claude.ai/install.sh")!, timeoutInterval: 30)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ClaudeSupportError.commandFailed }
        return data
    }
}

private final class ClaudeInstallerRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && ["claude.ai", "downloads.claude.ai"].contains(request.url?.host ?? "")
        completionHandler(allowed ? request : nil)
    }
}
