import SwiftUI

/// The Codex settings geometry is shared by all usage providers. Adapters supply data and actions only.
/// UI 2.0: usage pages use the shared type scale (ASB.Typeface); `language` is kept so
/// adapters do not change, but sizes no longer vary by language.
struct UsageSettingsTypography {
    let language: AppLanguage
    var title: Font { ASB.Typeface.bodyStrong }
    var body: Font { ASB.Typeface.caption }
    var strong: Font { ASB.Typeface.captionStrong }
    var detail: Font { ASB.Typeface.caption }
}

/// A usage card is a grouped box like every other settings group.
struct UsageSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ASBGroup(content: content)
    }
}

struct UsageControlSurface: View {
    @ObservedObject var model: MenuBarStatusModel
    var title: String? = nil
    var systemImage: String? = nil
    var width: CGFloat = 25
    @Environment(\.colorScheme) private var colorScheme
    private var fill: Color { .primary.opacity(colorScheme == .dark ? 0.10 : 0.05) }
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).frame(width: title == nil ? nil : 14) }
            if let title { Text(title).lineLimit(1).allowsTightening(true).minimumScaleFactor(0.72) }
        }
        .font(UsageSettingsTypography(language: model.appLanguage).strong)
        .foregroundStyle(.primary).padding(.horizontal, title == nil ? 0 : 9)
        .frame(width: width, height: 25)
        .background(RoundedRectangle(cornerRadius: ASB.Radius.control, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: ASB.Radius.control, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: ASB.Radius.control, style: .continuous))
    }
}

struct UsageActionButton: View {
    @ObservedObject var model: MenuBarStatusModel
    let title: String
    let systemImage: String
    var width: CGFloat = 83
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { UsageControlSurface(model: model, title: title, systemImage: systemImage, width: width) }
            .buttonStyle(.plain).disabled(disabled)
    }
}

struct UsageAccountIdentityRow: View {
    let language: AppLanguage
    let title: String
    let detail: String?
    let isActive: Bool
    let badge: String?
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isActive ? "person.crop.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(isActive ? Color.accentColor : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(ASB.Typeface.bodyStrong).lineLimit(1).truncationMode(.tail)
                        .minimumScaleFactor(0.82).frame(height: 17, alignment: .leading)
                    if let badge {
                        ASBStatusPill(text: badge, tone: .neutral)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(UsageSettingsTypography(language: language).detail).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
        }
    }
}

struct UsageDetailsDisclosure<Content: View>: View {
    @ObservedObject var model: MenuBarStatusModel
    @Binding var isExpanded: Bool
    var help: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.35)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(model.text("详情", "Details")).font(UsageSettingsTypography(language: model.appLanguage).strong)
                        .foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 10)
                    Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("usage-account-details")
            .accessibilityValue(isExpanded ? model.text("已展开", "Expanded") : model.text("已收起", "Collapsed"))
            .help(help ?? model.text("展开账户详情", "Expand account details"))
            if isExpanded { content().transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }
}

struct UsageAccountCard<Actions: View, Details: View, Messages: View>: View {
    @ObservedObject var model: MenuBarStatusModel
    let title: String
    let detail: String?
    let isActive: Bool
    let badge: String?
    let isRefreshing: Bool
    var isBusy = false
    let refreshHelp: String
    let refresh: () -> Void
    @Binding var detailsExpanded: Bool
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let details: () -> Details
    @ViewBuilder let messages: () -> Messages
    var body: some View {
        UsageSettingsCard {
            HStack(spacing: 8) {
                Text(model.text("账户", "Account")).font(UsageSettingsTypography(language: model.appLanguage).title)
                Spacer(minLength: 12)
                if isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.65) }
                Button(action: refresh) { UsageControlSurface(model: model, systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(isRefreshing || isBusy).help(refreshHelp)
                    .accessibilityLabel(refreshHelp)
            }
            VStack(alignment: .leading, spacing: 8) {
                UsageAccountIdentityRow(language: model.appLanguage, title: title, detail: detail, isActive: isActive, badge: badge)
                HStack(alignment: .center, spacing: 8) {
                    actions()
                    if isBusy { ProgressView().controlSize(.small).scaleEffect(0.65) }
                    Spacer(minLength: 0)
                }
                UsageDetailsDisclosure(model: model, isExpanded: $detailsExpanded, content: details)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            messages()
        }
        .font(UsageSettingsTypography(language: model.appLanguage).body)
        .controlSize(.small)
    }
}

/// One quota window: name and remaining share, a meter when the percent is known, and the reset.
struct UsageQuotaWindowTile: View {
    let language: AppLanguage
    let title: String
    let reset: String
    var remainingPercent: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(ASB.Typeface.bodyStrong).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(ASBTone.forRemainingPercent(remainingPercent) == .caution
                    || ASBTone.forRemainingPercent(remainingPercent) == .critical
                    ? ASBTone.forRemainingPercent(remainingPercent).foreground : Color.primary)
            if let remainingPercent {
                ASBMeter(fraction: remainingPercent / 100, tone: ASBTone.forRemainingPercent(remainingPercent))
            }
            Text(reset).font(ASB.Typeface.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct UsageTokenDashboard<Chart: View>: View {
    let language: AppLanguage
    let todayCost: String
    let monthCost: String
    let todayTokens: String
    let monthTokens: String
    @ViewBuilder let chart: () -> Chart
    private func text(_ zh: String, _ en: String) -> String { language.usesCompactLatinLayout ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: ASB.Space.m) {
            // Cost is the headline number; the token count sits under it.
            HStack(alignment: .top, spacing: ASB.Space.xl) {
                ASBStat(label: text("今日 · 本机", "Today · This Mac"), value: todayCost, detail: todayTokens)
                    .help(text("今日", "Today") + ": \(todayCost) · \(todayTokens)")
                ASBStat(label: text("近 30 天 · 本机", "Last 30 days · This Mac"), value: monthCost, detail: monthTokens)
                    .help(text("近 30 天", "Last 30 days") + ": \(monthCost) · \(monthTokens)")
            }
            chart()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
