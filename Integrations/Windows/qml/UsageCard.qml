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

    // Account and quota data are not ported yet; say so next to a live lamp.
    StatusPill {
        visible: App.liveData && !root.claude
        text: Theme.t("账号与额度为演示数据", "Account & quota: demo data")
        tone: "caution"
    }

    // Account and quota.
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
                    text: root.claude ? Theme.t("尚未读取账号", "Account not read") : root.account.email
                    caption: true
                    strong: true
                }
                AsbText {
                    visible: !root.claude
                    text: root.account.plan
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
            visible: root.claude
            text: Theme.t("暂无已验证配额", "No verified quota")
            caption: true
            secondary: true
        }
        RowLayout {
            visible: !root.claude
            Layout.fillWidth: true
            AsbText { text: root.account.source; caption: true; secondary: true; Layout.fillWidth: true }
            AsbText { text: root.account.updated; caption: true; secondary: true }
        }
        Repeater {
            model: root.claude ? [] : root.account.quotas
            QuotaLine {
                required property var modelData
                compact: true
                title: modelData.title
                valueText: Theme.t("剩余 ", "") + modelData.remaining + "%" + Theme.t("", " left")
                remainingPercent: modelData.remaining
                detail: modelData.reset
            }
        }
        RowLayout {
            visible: !root.claude
            Layout.fillWidth: true
            AsbText { text: root.account.resetCredits; caption: true; secondary: true; Layout.fillWidth: true }
            Icon { name: "clock"; size: 11; color: Theme.secondary }
            AsbText { text: root.account.resetCreditsDetail; caption: true; secondary: true }
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
