import Foundation

struct CodexServiceStatus: Equatable, Sendable {
    enum Indicator: String, Equatable, Sendable {
        case none
        case minor
        case major
        case critical
        case maintenance
        case unknown

        var fallbackDescription: String {
            switch self {
            case .none:
                return "All Systems Operational"
            case .minor:
                return "Partial System Degradation"
            case .major:
                return "Major Service Outage"
            case .critical:
                return "Critical Service Outage"
            case .maintenance:
                return "Under Maintenance"
            case .unknown:
                return "Unknown"
            }
        }
    }

    let indicator: Indicator
    let description: String?
    let updatedAt: Date?

    var displayText: String {
        guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else {
            return indicator.fallbackDescription
        }
        return description
    }
}

final class CodexServiceStatusFetcher: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSessionProtocol

    init(
        baseURL: URL = URL(string: "https://status.openai.com/")!,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetch() async throws -> CodexServiceStatus {
        let url = baseURL.appendingPathComponent("api/v2/status.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, _) = try await session.data(for: request)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodexServiceStatus {
        struct Response: Decodable {
            struct Status: Decodable {
                let indicator: String
                let description: String?
            }

            struct Page: Decodable {
                let updatedAt: String?

                private enum CodingKeys: String, CodingKey {
                    case updatedAt = "updated_at"
                }
            }

            let page: Page?
            let status: Status
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let indicator = CodexServiceStatus.Indicator(rawValue: response.status.indicator) ?? .unknown
        return CodexServiceStatus(
            indicator: indicator,
            description: response.status.description,
            updatedAt: response.page?.updatedAt.flatMap(parseDate)
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
