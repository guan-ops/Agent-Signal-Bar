import SwiftUI

/// One panel surface and choice geometry for every provider and both floating usage badges.
struct FloatingUsagePanel<Content: View>: View {
    var width: CGFloat = 286
    var scrollHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        Group {
            if let scrollHeight {
                ScrollView { stack }.scrollBounceBehavior(.basedOnSize).frame(height: min(550, scrollHeight))
            } else { stack }
        }
        .frame(width: width, alignment: .leading)
        // UI 2.0: system material that follows light/dark, not a fixed black card.
        .asbPanelSurface()
        .padding(8)
    }
    private var stack: some View {
        VStack(alignment: .leading, spacing: ASB.Space.s, content: content).padding(ASB.Space.m)
    }
}

struct FloatingUsageIdentity: View {
    let title: String
    let context: String
    var detail: String? = nil
    var identifier: String? = nil
    let refreshLabel: String
    var isRefreshing = false
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(ASB.Typeface.bodyStrong).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                .buttonStyle(.borderless).disabled(isRefreshing).accessibilityLabel(refreshLabel).help(refreshLabel)
        }
        Text(context).font(ASB.Typeface.caption).foregroundStyle(.secondary)
            .lineLimit(2).truncationMode(.tail)
        if let identifier {
            Text("ID · " + identifier).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if let detail {
            Text(detail).font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct FloatingUsageChoiceRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var available = true
    /// When set, a quota meter is drawn under the title.
    var remainingPercent: Double? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain).focusable(false)
            } else { row.accessibilityElement(children: .combine) }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(title + "\n" + subtitle)
    }
    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ASB.Typeface.bodyStrong).foregroundStyle(available ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let remainingPercent {
                    ASBMeter(fraction: remainingPercent / 100, tone: ASBTone.forRemainingPercent(remainingPercent), height: 4)
                }
                Text(subtitle).font(ASB.Typeface.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            // A native-style radio button.
            ZStack {
                if isSelected {
                    Circle().fill(Color.accentColor)
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.2)
                }
            }.frame(width: 15, height: 15).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 31, alignment: .leading).contentShape(Rectangle())
    }
}

struct UsageBalanceSection<Details: View>: View {
    let title: String
    let value: String
    @ViewBuilder let details: () -> Details
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).monospacedDigit().fixedSize()
            }
            details()
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
