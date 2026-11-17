import SwiftUI

struct ClaudeAccountsOverviewView: View {
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var support: ClaudeSupportModel
    @State private var showAll = false
    var body: some View {
        if support.swapEnabled && !support.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.text("账号额度对比", "Account quota comparison")).fontWeight(.semibold)
                    Spacer()
                    if support.accountsAreStale { Text(model.text("上次读取", "Previous capture")).foregroundStyle(.orange) }
                }
                ForEach(showAll ? ordered : Array(ordered.prefix(3)), id: \.number) { account in
                    Button { support.inspectedAccountNumber = support.inspectedAccountNumber == account.number ? nil : account.number } label: {
                        HStack {
                            Text(support.accountLabel(account)).lineLimit(1).truncationMode(.middle)
                            if account.isActive { Image(systemName: "checkmark.circle.fill") }
                            if account.number == support.bestAvailableAccount { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            Spacer(minLength: 4)
                            Text("5h \(percent(account.fiveHour)) · 7d \(percent(account.sevenDay))").monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if support.inspectedAccountNumber == account.number {
                        VStack(alignment: .leading, spacing: 4) {
                            let state = ClaudeAccountPresentation.status(account)
                            Text(model.text(state.zh, state.en)).foregroundStyle(.secondary)
                            window(model.text("5 小时", "5 hours"), account.fiveHour)
                            window(model.text("7 天", "7 days"), account.sevenDay)
                            ForEach(account.scoped, id: \.name) { scoped in
                                window(scoped.name, .init(usedPercent: scoped.usedPercent, resetsAt: scoped.resetsAt))
                            }
                            if !account.isActive || account.usageStatus == .foreignCredential {
                                Button(model.text("切换到此账号", "Switch to this account")) { support.switchAccount(account.number) }
                                    .disabled(!support.canSwitchAccount(account))
                            }
                        }.padding(.leading, 8)
                    }
                }
                if ordered.count > 3 {
                    Button(showAll ? model.text("收起", "Show less") : model.text("查看全部 \(ordered.count) 个账号", "Show all \(ordered.count) accounts")) { showAll.toggle() }
                }
            }.font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var ordered: [ClaudeSwapAccountRow] {
        support.accounts.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            let a = [$0.fiveHour, $0.sevenDay].compactMap { $0?.usedPercent }.max() ?? -1
            let b = [$1.fiveHour, $1.sevenDay].compactMap { $0?.usedPercent }.max() ?? -1
            return a == b ? $0.number < $1.number : a > b
        }
    }
    private func percent(_ window: ClaudeSwapUsageWindow?) -> String {
        window.map { "\(Int((100 - $0.usedPercent).rounded()))%" } ?? "—"
    }
    @ViewBuilder private func window(_ title: String, _ value: ClaudeSwapUsageWindow?) -> some View {
        if let value {
            HStack { Text(title); Spacer(); Text(percent(value)) }
            if let reset = value.resetsAt { Text(model.text("重置 ", "Resets ") + model.localizedDateTimeString(for: reset)).foregroundStyle(.secondary) }
        }
    }
}
