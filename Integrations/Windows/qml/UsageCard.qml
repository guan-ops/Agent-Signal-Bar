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
    readonly property var days: Demo.days(Theme.t)
    readonly property bool claude: App.prefs.usagePlatform === "claude"

    Layout.fillWidth: true
    spacing: Theme.m

    PlatformSwitcher {}

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
                value: root.claude ? "—" : root.account.today.cost
                detail: root.claude ? "—" : root.account.today.tokens
            }
            AsbStat {
                label: Theme.t("近 30 天", "30 days")
                value: root.claude ? "—" : root.account.month.cost
                detail: root.claude ? "—" : root.account.month.tokens
            }
        }
        AsbText { text: Theme.t("近 30 天 Token", "30-day tokens"); caption: true; secondary: true; Layout.topMargin: 5 }
        TokenChart {
            id: chart
            days: root.claude ? [] : root.days
            chartHeight: 46
        }
        AsbText {
            Layout.bottomMargin: 5
            text: chart.hovered >= 0
                ? chart.shown.label + " · " + (App.language === "zh" ? (chart.shown.total * 100).toFixed(2) + "万 Token"
                                                                  : chart.shown.total.toFixed(2) + "M tokens")
                : Theme.t("悬停查看每日 Token 与费用", "Hover for daily tokens and cost")
            caption: true
            secondary: true
        }
        AsbText {
            visible: !root.claude
            text: Theme.t("最常用模型：", "Top model: ") + root.account.topModel
            caption: true
        }
        AsbText { text: Theme.t("本机汇总 · 费用为估算，并非订阅账单", "This PC · Estimated cost, not a subscription bill"); caption: true; secondary: true }
        RowLayout {
            visible: !root.claude
            spacing: 5
            Icon { name: "check"; size: 11; color: Theme.secondary }
            AsbText { text: root.account.scan; caption: true; secondary: true }
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
