import Foundation

enum CodexPlanFormatting {
    private static let exactDisplayNames: [String: String] = [
        "pro": "Pro 20x",
        "prolite": "Pro 5x",
        "pro_lite": "Pro 5x",
        "pro-lite": "Pro 5x",
        "pro lite": "Pro 5x"
    ]

    private static let uppercaseWords: Set<String> = [
        "cbp",
        "k12"
    ]

    static func displayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        let lower = raw.lowercased()
        if let exact = exactDisplayNames[lower] {
            return exact
        }

        let cleaned = cleanPlanName(raw)
        let candidate = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return raw }

        if let exact = exactDisplayNames[candidate.lowercased()] {
            return exact
        }

        let components = candidate
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return candidate }
        let formatted = components.map(wordDisplayName).joined(separator: " ")
        return formatted.isEmpty ? candidate : formatted
    }

    private static func cleanPlanName(_ raw: String) -> String {
        raw
            .replacingOccurrences(
                of: #"\b(claude|codex|account|plan)\b"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordDisplayName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if uppercaseWords.contains(lower) {
            return lower.uppercased()
        }
        if raw == raw.uppercased(), raw.contains(where: \.isLetter) {
            return raw
        }
        if let first = raw.first, first.isLowercase {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return raw
    }
}
