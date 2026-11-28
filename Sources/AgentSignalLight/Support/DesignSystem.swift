import AgentSignalLightCore
import AppKit
import SwiftUI

/// Agent Signal Bar UI 2.0. Every surface (settings, menu bar panel, floating light and its
/// popovers) takes type, spacing, radii and colors from here, so the four surfaces stay one
/// product. Red, yellow and green are reserved for the light language.
enum ASB {
    /// Five sizes replace the thirteen ad-hoc ones the views used before.
    enum Typeface {
        static let value = Font.system(size: 22, weight: .bold).monospacedDigit()
        static let title = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 11)
        static let captionStrong = Font.system(size: 11, weight: .semibold)
        static let badge = Font.system(size: 10, weight: .semibold)
    }

    /// A 4-point scale.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 6
        static let group: CGFloat = 10
        static let panel: CGFloat = 14
    }

    enum Palette {
        /// Grouped boxes: white on the light window background, raised gray in dark mode.
        static let groupFill = dynamic(light: .white, dark: NSColor(calibratedWhite: 0.172, alpha: 1))
        /// How dark a grouped box is on glass in dark mode: 0 shows the glass untouched, 1 is black.
        static let glassGroupDarkOpacity: CGFloat = 0.25
        /// Grouped boxes on a glass surface before macOS 26, where there is no Liquid Glass. In
        /// dark mode the box is smoked glass instead of an opaque gray card, so the surface and
        /// the colors behind it stay visible. Light mode keeps the white box.
        static let glassGroupFill = dynamic(
            light: .white, dark: NSColor(calibratedWhite: 0, alpha: glassGroupDarkOpacity))
        static let groupStroke = dynamic(
            light: NSColor(calibratedWhite: 0, alpha: 0.07), dark: NSColor(calibratedWhite: 1, alpha: 0.07))
        static let track = dynamic(
            light: NSColor(calibratedWhite: 0, alpha: 0.10), dark: NSColor(calibratedWhite: 1, alpha: 0.14))
        static let lampGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
        static let lampYellow = Color(red: 1.0, green: 0.72, blue: 0.0)
        static let lampRed = Color(red: 1.0, green: 0.23, blue: 0.19)
        static let lampGray = Color(red: 0.56, green: 0.56, blue: 0.58)

        static func dynamic(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }
}

/// The meaning a color carries. Text colors are darker than the lamp colors so 11 pt labels
/// keep a 4.5:1 contrast on their tinted capsule in both appearances.
enum ASBTone: Equatable {
    case positive, caution, critical, neutral, accent

    static func forDisplayState(_ state: DisplayState) -> ASBTone {
        switch state {
        case .ready, .active, .completed: return .positive
        case .needsReview, .stale: return .caution
        case .permission, .blocked: return .critical
        case .paused: return .neutral
        }
    }

    /// Remaining quota: plenty is the accent, low is a caution, exhausted is critical.
    static func forRemainingPercent(_ remaining: Double?) -> ASBTone {
        guard let remaining else { return .neutral }
        if remaining <= 0 { return .critical }
        return remaining < 20 ? .caution : .accent
    }

    var lamp: Color {
        switch self {
        case .positive: return ASB.Palette.lampGreen
        case .caution: return ASB.Palette.lampYellow
        case .critical: return ASB.Palette.lampRed
        case .neutral: return ASB.Palette.lampGray
        case .accent: return .accentColor
        }
    }

    var foreground: Color {
        switch self {
        case .positive:
            return ASB.Palette.dynamic(light: NSColor(srgbRed: 0.09, green: 0.42, blue: 0.18, alpha: 1),
                                       dark: NSColor(srgbRed: 0.36, green: 0.82, blue: 0.48, alpha: 1))
        case .caution:
            return ASB.Palette.dynamic(light: NSColor(srgbRed: 0.48, green: 0.32, blue: 0.0, alpha: 1),
                                       dark: NSColor(srgbRed: 1.0, green: 0.82, blue: 0.37, alpha: 1))
        case .critical:
            return ASB.Palette.dynamic(light: NSColor(srgbRed: 0.65, green: 0.11, blue: 0.07, alpha: 1),
                                       dark: NSColor(srgbRed: 1.0, green: 0.50, blue: 0.46, alpha: 1))
        case .neutral:
            return .secondary
        case .accent:
            return .accentColor
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.08)
        case .accent: return Color.accentColor.opacity(0.14)
        default: return lamp.opacity(0.16)
        }
    }
}

/// A titled group of rows in a raised box, like a grouped System Settings form.
struct ASBSection<Content: View>: View {
    var title: String?
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(ASB.Typeface.bodyStrong)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            ASBGroup(content: content)
            if let footer {
                Text(footer)
                    .font(ASB.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The raised box itself. It never clips, so inline menus can extend past its edges.
struct ASBGroup<Content: View>: View {
    var padding: CGFloat = ASB.Space.m
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ASB.Palette.groupFill, in: RoundedRectangle(cornerRadius: ASB.Radius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ASB.Radius.group, style: .continuous)
                    .strokeBorder(ASB.Palette.groupStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

/// Title, optional explanation, and a trailing control.
struct ASBRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: ASB.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ASB.Typeface.body).fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ASB.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ASB.Space.s)
            trailing()
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
}

/// A short state label on a tinted capsule (执行中, 等待授权, 已连接…).
struct ASBStatusPill: View {
    let text: String
    let tone: ASBTone

    var body: some View {
        Text(text)
            .font(ASB.Typeface.caption)
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }
}

/// A quota or progress bar whose fill color follows the tone.
struct ASBMeter: View {
    let fraction: Double
    var tone: ASBTone = .accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ASB.Palette.track)
                Capsule()
                    .fill(tone.lamp)
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
    }
}

/// A quota line: name, remaining percent, meter and reset time, shared by settings,
/// the menu bar panel and the floating light popover.
struct ASBQuotaLine: View {
    let title: String
    let valueText: String
    let remainingPercent: Double?
    var detail: String? = nil
    var compact = false

    var body: some View {
        let tone = ASBTone.forRemainingPercent(remainingPercent)
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: ASB.Space.s)
                Text(valueText)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(tone == .accent || tone == .neutral ? Color.primary : tone.foreground)
                    .lineLimit(1)
            }
            .font(compact ? .system(size: 12) : ASB.Typeface.body)
            ASBMeter(fraction: (remainingPercent ?? 0) / 100, tone: tone, height: compact ? 5 : 6)
            if let detail, !detail.isEmpty {
                Text(detail).font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A big number with its label and an optional second line (今日 · 本机 / ≥ US$30.00 / 300 万 token).
struct ASBStat: View {
    let label: String
    let value: String
    var detail: String? = nil
    var valueFont: Font = ASB.Typeface.value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(valueFont).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let detail, !detail.isEmpty {
                Text(detail).font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A row that behaves like a menu item (hover highlight, trailing shortcut), so the card
/// panel's actions read the same as the native status menu.
struct ASBMenuRow: View {
    let title: String
    var shortcut: String? = nil
    var systemImage: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ASB.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage).frame(width: 16)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: ASB.Space.s)
                if let shortcut {
                    Text(shortcut).foregroundStyle(isHovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(ASB.Typeface.body)
            .foregroundStyle(isHovering ? Color.white : Color.primary)
            .padding(.horizontal, ASB.Space.s)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A floating surface (popovers, the menu bar panel): system material that follows the
/// light/dark appearance instead of a fixed black card.
struct ASBPanelSurface: ViewModifier {
    var cornerRadius: CGFloat = ASB.Radius.panel

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

/// A grouped box on a glass surface (the status menu, the menu bar panel). On macOS 26 and
/// later the box is Liquid Glass, like the system's own controls, so the menu's glass and the
/// colors behind it stay visible. Earlier systems get a see-through fill, and Reduce
/// Transparency gets the solid box.
struct ASBGlassGroupBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ASB.Radius.group, style: .continuous)
        if reduceTransparency {
            content.asbGroupBackground()
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(ASB.Palette.glassGroupFill, in: shape)
                .overlay(shape.strokeBorder(ASB.Palette.groupStroke, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

extension View {
    /// The grouped-box background for views that build their own padding and layout.
    func asbGroupBackground() -> some View {
        background(ASB.Palette.groupFill, in: RoundedRectangle(cornerRadius: ASB.Radius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ASB.Radius.group, style: .continuous)
                    .strokeBorder(ASB.Palette.groupStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    /// The grouped-box background for views that sit on a glass or material surface.
    func asbGlassGroupBackground() -> some View {
        modifier(ASBGlassGroupBackground())
    }

    /// The floating light's corner badges: an adaptive chip with a hairline and a soft
    /// shadow, so it reads on any wallpaper in light and dark mode.
    func asbBadgeBackground() -> some View {
        background(
            Circle()
                .fill(ASB.Palette.groupFill)
                .overlay(Circle().strokeBorder(ASB.Palette.groupStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        )
    }

    /// A tile nested inside a group: one subtle fill instead of per-view grays.
    func asbInsetTile() -> some View {
        background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: ASB.Radius.control, style: .continuous))
    }

    func asbPanelSurface(cornerRadius: CGFloat = ASB.Radius.panel) -> some View {
        modifier(ASBPanelSurface(cornerRadius: cornerRadius))
    }
}
