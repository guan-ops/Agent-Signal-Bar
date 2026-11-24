import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// MenuUsageSummaryView (1.7.0): provider switch + refresh, an account & quota group,
// a device-usage group, then the "Usage & account settings…" link. `nativeMenu` is the
// system-menu variant (chevron instead of the account menu button).
ColumnLayout {
    id: root
    property bool nativeMenu: false
    signal openSettings()
    readonly property var account: Demo.account(Theme.t)
    readonly property bool claude: App.prefs.usagePlatform === "claude"
    // Device usage: the local scan when live, else the demo set (Codex only).
    readonly property var usage: App.liveData ? (App.usage[root.claude ? "claude" : "codex"] || null)
                                              : (root.claude ? null : Demo.usage(Theme.t))

    Layout.fillWidth: true
    spacing: Theme.m

    PlatformSwitcher {}

    // Without this PC's account data (demo and fixture runs) the account part is demo data.
    StatusPill {
        visible: App.liveData && !root.claude && root.live === null
        text: Theme.t("账号与额度为演示数据", "Account & quota: demo data")
        tone: "caution"
    }

    // Account and quota: App.quota when live, else the demo account (Codex only).
    readonly property var live: App.liveData && App.quota[root.claude ? "claude" : "codex"] !== undefined
        ? App.quota[root.claude ? "claude" : "codex"] : null
    readonly property var quotaRows: root.live ? root.live.windows
        : root.claude ? [] : root.account.quotas.map(q => ({ title: q.title, remaining: q.remaining, reset: q.reset,
                                                            valueText: Theme.t("剩余 ", "") + q.remaining + "%" + Theme.t("", " left") }))
    AsbGroup {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            AsbText {
                text: root.claude ? "Claude" : "Codex"
                strong: true
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
            }
            ColumnLayout {
                spacing: 3
                AsbText {
                    text: root.live
                        ? (root.live.email || (root.claude ? (root.live.ready ? "Claude" : Theme.t("尚未读取账号", "Account not read"))
                                                           : (root.live.signedIn ? Theme.t("已登录", "Signed in") : Theme.t("未登录", "Not signed in"))))
                        : root.claude ? Theme.t("尚未读取账号", "Account not read") : root.account.email
                    caption: true
                    strong: true
                }
                AsbText {
                    visible: text.length > 0
                    text: root.live ? (root.live.plan || "") : root.claude ? "" : root.account.plan
                    caption: true
                    secondary: true
                }
            }
            Icon {
                name: root.nativeMenu ? "chevronRight" : "person"
                size: 14
                color: Theme.secondary
                Layout.alignment: Qt.AlignTop
            }
        }
        AsbText {
            visible: text.length > 0
            text: root.live ? (root.live.status || (root.quotaRows.length === 0 ? Theme.t("暂无已验证配额", "No verified quota") : ""))
                            : root.claude ? Theme.t("暂无已验证配额", "No verified quota") : ""
            caption: true
            color: root.live && root.live.status ? Theme.toneForeground("caution") : Theme.secondary
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            visible: root.live ? root.live.ready : !root.claude
            Layout.fillWidth: true
            AsbText { text: root.live ? root.live.source : root.account.source; caption: true; secondary: true; Layout.fillWidth: true }
            AsbText { text: root.live ? root.live.updated : root.account.updated; caption: true; secondary: true }
        }
        Repeater {
            model: root.quotaRows
            QuotaLine {
                required property var modelData
                compact: true
                title: modelData.title
                valueText: modelData.valueText
                remainingPercent: modelData.remaining
                detail: modelData.reset
            }
        }
        RowLayout {
            visible: !root.claude && (root.live ? root.live.resetCredits.title !== undefined : true)
            Layout.fillWidth: true
            AsbText {
                text: root.live ? (root.live.resetCredits.title ? Theme.t("限额重置额度 · ", "Limit resets · ") + root.live.resetCredits.title : "")
                                : root.account.resetCredits
                caption: true
                secondary: true
                Layout.fillWidth: true
            }
            Icon { name: "clock"; size: 11; color: Theme.secondary }
            AsbText { text: root.live ? (root.live.resetCredits.detail || "") : root.account.resetCreditsDetail; caption: true; secondary: true }
        }
    }

    // Device usage.
    AsbGroup {
        spacing: 5
        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            AsbStat {
                label: Theme.t("今日", "Today")
                value: root.usage ? root.usage.today.costText : "—"
                detail: root.usage ? root.usage.today.tokensText : "—"
            }
            AsbStat {
                label: Theme.t("近 30 天", "30 days")
                value: root.usage ? root.usage.month.costText : "—"
                detail: root.usage ? root.usage.month.tokensText : "—"
            }
        }
        AsbText { text: Theme.t("近 30 天 Token", "30-day tokens"); caption: true; secondary: true; Layout.topMargin: 5 }
        TokenChart {
            id: chart
            days: root.usage ? root.usage.days : []
            chartHeight: 46
        }
        AsbText {
            Layout.bottomMargin: 5
            text: chart.hovered >= 0 && chart.shown
                ? chart.shown.label + " · " + chart.shown.costText + " · " + chart.shown.tokensText
                : Theme.t("悬停查看每日 Token 与费用", "Hover for daily tokens and cost")
            caption: true
            secondary: true
        }
        AsbText {
            visible: root.usage !== null && root.usage.topModel !== "—"
            text: Theme.t("最常用模型：", "Top model: ") + (root.usage ? root.usage.topModel : "")
            caption: true
        }
        AsbText {
            visible: text.length > 0
            text: root.usage ? (root.usage.status || root.usage.empty || "") : ""
            caption: true
            color: Theme.toneForeground("caution")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbText { text: Theme.t("本机汇总 · 费用为估算，并非订阅账单", "This PC · Estimated cost, not a subscription bill"); caption: true; secondary: true }
        RowLayout {
            visible: root.usage !== null
            spacing: 5
            Icon { name: root.usage && root.usage.ready && !root.usage.scanning ? "check" : "refresh"; size: 11; color: Theme.secondary }
            AsbText { text: root.usage ? root.usage.scan : ""; caption: true; secondary: true }
        }
    }

    AsbText {
        text: Theme.t("用量与账号设置…", "Usage & account settings…")
        caption: true
        color: Theme.accent
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openSettings()
        }
    }
}
