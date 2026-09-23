import SwiftUI

struct CostCurrencySettingsView<CurrencyRow: View>: View {
    @ObservedObject var store: CostCurrencyStore
    let text: (String, String) -> String
    @ViewBuilder var currencyRow: CurrencyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            currencyRow
                .zIndex(1)
            Text(text("今日与历史费用均按最新可用汇率估算。账号额外用量保留账单币种。",
                      "Today’s and historical costs use the latest available rate. Account extra usage keeps its billing currency."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.preferredCode != "USD" {
                HStack(alignment: .top) {
                    CostCurrencyRateNote(store: store, text: text)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Button {
                            store.requestRefresh(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).disabled(!store.canRefresh)
                        .accessibilityLabel(text("刷新汇率", "Refresh exchange rates"))
                        .help(text("刷新汇率（每天更新）", "Refresh exchange rates (updated daily)"))
                    }
                }
            }
        }
        .onAppear { store.requestRefresh() }
        .onChange(of: store.preferredCode) { _, _ in store.requestRefresh() }
    }
}

/// Dated attribution accompanies converted estimates, including cached and missing-rate states.
struct CostCurrencyRateNote: View {
    @ObservedObject var store: CostCurrencyStore
    let text: (String, String) -> String
    var compact = false

    var body: some View {
        if store.preferredCode != "USD" {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("ExchangeRate-API", destination: URL(string: "https://www.exchangerate-api.com")!)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(text("汇率来源，每天更新一次", "Exchange rate source, updated once a day"))
                }
                .font(compact ? .caption2 : .caption)
            }
            .onAppear { store.requestRefresh() }
        }
    }

    private var statusText: String {
        guard let snapshot = store.snapshot, let rate = snapshot.rates[store.preferredCode] else {
            return store.isRefreshing
                ? text("正在获取汇率，暂以 USD 显示", "Fetching exchange rates; showing USD for now")
                : text("汇率暂不可用，以 USD 显示", "Exchange rate unavailable; showing USD")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: snapshot.updatedAt) + " UTC"
        let state = store.refreshFailed ? text(" · 更新失败，使用缓存", " · update failed, using cache")
            : store.isUsingStaleRates ? text(" · 缓存汇率", " · cached rate") : ""
        let value = rate.formatted(.number.precision(.fractionLength(0...4)).locale(Locale(identifier: "en_US")))
        return "1 USD ≈ \(value) \(store.preferredCode) · \(date)\(state)"
    }
}
