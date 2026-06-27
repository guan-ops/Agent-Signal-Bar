import Foundation
#if os(macOS)
import SweetCookieKit
#endif

struct OpenAIBrowserCookieImportResult: Equatable, Sendable {
    let cookieHeader: String
    let sourceLabel: String
    let debugLog: String
}

protocol OpenAIBrowserCookieImporting: Sendable {
    func importCookieHeader() async -> OpenAIBrowserCookieImportResult?
}

struct OpenAIBrowserCookieImporter: OpenAIBrowserCookieImporting {
    func importCookieHeader() async -> OpenAIBrowserCookieImportResult? {
        #if os(macOS)
        await Task.detached(priority: .utility) {
            let client = BrowserCookieClient()
            let query = BrowserCookieQuery(
                domains: ["chatgpt.com", "openai.com"],
                domainMatch: .suffix,
                origin: .fixed(URL(string: "https://chatgpt.com")!)
            )
            var logLines: [String] = []

            for browser in Browser.defaultImportOrder {
                do {
                    let sources = try client.records(matching: query, in: browser) { message in
                        logLines.append("[\(browser.displayName)] \(message)")
                    }
                    for source in sources {
                        let cookies = source.cookies(origin: query.origin)
                        guard let header = Self.cookieHeader(from: cookies) else {
                            continue
                        }
                        logLines.append("Loaded \(cookies.count) cookies from \(source.label).")
                        return OpenAIBrowserCookieImportResult(
                            cookieHeader: header,
                            sourceLabel: source.label,
                            debugLog: logLines.joined(separator: "\n")
                        )
                    }
                    if !sources.isEmpty {
                        logLines.append("\(browser.displayName) had matching records but no usable Cookie header.")
                    }
                } catch {
                    logLines.append("\(browser.displayName): \(error.localizedDescription)")
                }
            }

            return nil
        }.value
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
        let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let header, !header.isEmpty else { return nil }
        return header
    }
    #endif
}
