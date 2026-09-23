import SwiftUI

/// GPT-6 colors follow the user-provided Astra/Sol/Luna character artwork.
/// Keep names beside colors so the chart never relies on color alone.
struct CodexModelPresentation: Equatable {
    let displayName: String
    let sortRank: Int
    let colorRGB: UInt32?

    var color: Color {
        guard let colorRGB else { return .secondary }
        return Color(
            red: Double((colorRGB >> 16) & 0xff) / 255,
            green: Double((colorRGB >> 8) & 0xff) / 255,
            blue: Double(colorRGB & 0xff) / 255)
    }

    static func forModel(_ raw: String) -> Self {
        let model = CostUsagePricing.normalizeCodexModel(raw.lowercased())
        switch model {
        case "gpt-6-astra": return Self(displayName: "GPT-6 Astra", sortRank: 0, colorRGB: 0x6F52F0)
        case "gpt-6-sol": return Self(displayName: "GPT-6 Sol", sortRank: 1, colorRGB: 0xE85028)
        case "gpt-6-luna": return Self(displayName: "GPT-6 Luna", sortRank: 2, colorRGB: 0xF8D068)
        case "gpt-5.6-sol": return Self(displayName: "GPT-5.6 Sol", sortRank: 10, colorRGB: 0xD56F9B)
        case "gpt-5.6-terra": return Self(displayName: "GPT-5.6 Terra", sortRank: 11, colorRGB: 0x6BAB73)
        case "gpt-5.6-luna": return Self(displayName: "GPT-5.6 Luna", sortRank: 12, colorRGB: 0x4CB8B0)
        case "gpt-5.5": return Self(displayName: "GPT-5.5", sortRank: 20, colorRGB: 0x919BB0)
        default: break
        }

        let legacyFamilies: [(String, Int, UInt32)] = [
            ("gpt-5.5", 20, 0x919BB0), ("gpt-5.4", 30, 0xC3AA55),
            ("gpt-5.3", 40, 0xCE8071), ("gpt-5.2", 50, 0x7C97C4),
            ("gpt-5.1", 60, 0x91A66A), ("gpt-5", 70, 0x8B889F),
        ]
        for (family, rank, rgb) in legacyFamilies
            where model == family || model.hasPrefix(family + "-") {
            return Self(displayName: raw, sortRank: rank, colorRGB: rgb)
        }
        if model == "codex-auto-review" {
            return Self(displayName: raw, sortRank: 80, colorRGB: 0xB69684)
        }
        return Self(displayName: raw, sortRank: model == "__other__" ? 900 : 800, colorRGB: nil)
    }
}
