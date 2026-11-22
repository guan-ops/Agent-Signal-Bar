import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// 用量 / Usage: account, quota windows, reset credits, token usage, projects.
SettingsPage {
    id: page
    readonly property var account: Demo.account(Theme.t)
    readonly property bool claude: App.prefs.usagePlatform === "claude"
    // Local token usage: the scan when live, else the demo set (Codex only).
    readonly property var usage: App.liveData ? (App.usage[page.claude ? "claude" : "codex"] || null)
                                              : (page.claude ? null : Demo.usage(Theme.t))

    RowLayout {
        Layout.fillWidth: true
        AsbText {
            text: Theme.t("用量", "Usage")
            font.pixelSize: Theme.titleSize
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        StatusPill {
            visible: App.liveData && !page.claude
            text: Theme.t("账号与额度为演示数据", "Account & quota: demo data")
            tone: "caution"
        }
        Dropdown {
            key: "usagePlatform"
            icon: page.claude ? "sparkles" : "terminal"
            pickerWidth: 124
            options: [{ value: "codex", label: "Codex" }, { value: "claude", label: "Claude" }]
        }
    }

    ClaudeUsageCard { visible: page.claude }

    // Account.
    AsbSection {
        visible: !page.claude
        title: Theme.t("账户", "Account")
        headerAccessory: AsbButton { icon: "refresh"; implicitWidth: 28 }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                width: 30
                height: 30
                radius: 15
                color: Theme.accent
                Icon { anchors.centerIn: parent; name: "person"; size: 18; color: Theme.textOnAccent }
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                RowLayout {
                    AsbText { text: page.account.email; strong: true }
                    StatusPill { text: Theme.t("默认", "Default"); tone: "neutral" }
                }
                AsbText { text: page.account.plan; caption: true; secondary: true }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s
            AsbButton { icon: "personAdd"; text: Theme.t("添加账号", "Add Account") }
            Dropdown {
                pickerWidth: 150
                value: "demo"
                options: [{ value: "demo", label: Theme.t("切换", "Switch") }]
            }
            AsbButton { icon: "ellipsis"; implicitWidth: 32 }
            Item { Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        RowLayout {
            Layout.fillWidth: true
            AsbText { text: Theme.t("详情", "Details"); strong: true; Layout.fillWidth: true }
            Icon { name: "chevronDown"; size: 13; color: Theme.secondary }
        }
    }

    // Session quota windows.
    AsbSection {
        visible: !page.claude
        title: Theme.t("会话", "Session")
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                AsbText { text: "Codex"; strong: true; Layout.fillWidth: true }
                AsbText { text: page.account.source; caption: true; secondary: true }
                AsbText { text: "ID · codex"; caption: true; color: Theme.tertiary }
            }
            AsbText { text: page.account.updated; caption: true; color: Theme.tertiary; Layout.alignment: Qt.AlignTop }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s
            Repeater {
                model: page.account.quotas
                Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: quotaColumn.implicitHeight + 16
                    radius: Theme.radiusControl
                    color: Theme.insetTile
                    ColumnLayout {
                        id: quotaColumn
                        x: 9
                        y: 8
                        width: parent.width - 18
                        spacing: 2
                        AsbText {
                            text: modelData.title + Theme.t(" · 剩余 ", " · ") + modelData.remaining + "%" + Theme.t("", " left")
                            strong: true
                        }
                        AsbText { text: modelData.reset; caption: true; secondary: true; Layout.fillWidth: true }
                    }
                }
            }
        }
    }

    AsbSection {
        visible: !page.claude
        title: Theme.t("限额重置额度", "Limit Reset Credits")
        RowLayout {
            Layout.fillWidth: true
            AsbText { text: Theme.t("0 次可用", "0 available"); strong: true; Layout.fillWidth: true }
            Icon { name: "clock"; size: 12; color: Theme.secondary }
            AsbText { text: page.account.resetCreditsDetail; caption: true; secondary: true }
        }
    }

    // Token usage (Codex: CodexUsageDetailsView; Claude: ClaudeUsageSettingsView.historyCard).
    AsbSection {
        visible: page.usage !== null
        title: page.claude ? Theme.t("本机 Token 使用", "Local Token Usage") : Theme.t("Token 使用", "Token Usage")
        headerAccessory: AsbButton {
            visible: App.liveData
            icon: "refresh"
            implicitWidth: 28
            enabled: page.usage !== null && !page.usage.scanning
            onClicked: App.refreshUsage()
        }
        AsbText {
            text: page.claude
                ? Theme.t("汇总本机 Claude Code 会话日志，包含缓存 Token；切换账号不影响统计范围。费用为估算，并非订阅账单。",
                          "Local Claude Code session logs including cached tokens, across accounts. Costs are estimates, not subscription charges.")
                : Theme.t("本机 Codex 会话汇总，不归属于当前所选账号。", "Local Codex sessions, not attributed to the selected account.")
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            spacing: 5
            Icon { name: page.usage && page.usage.ready && !page.usage.scanning ? "check" : "refresh"; size: 12; color: Theme.secondary }
            AsbText { text: page.usage ? page.usage.scan : ""; caption: true; secondary: true }
        }
        AsbText {
            visible: text.length > 0
            text: page.usage ? (page.usage.status || "") : ""
            caption: true
            color: Theme.toneForeground("caution")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: tokenColumn.implicitHeight + 20
            radius: Theme.radiusControl
            color: Theme.insetTile
            ColumnLayout {
                id: tokenColumn
                x: 10
                y: 10
                width: parent.width - 20
                spacing: 10
                GridLayout {
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 8
                    Layout.fillWidth: true
                    AsbStat { label: Theme.t("今日", "Today"); value: page.usage ? page.usage.today.costText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天费用", "30-day cost"); value: page.usage ? page.usage.month.costText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("今日 token 用量", "Today's tokens"); value: page.usage ? page.usage.today.tokensText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天 token 用量", "30-day tokens"); value: page.usage ? page.usage.month.tokensText : "—"; valueSize: Theme.bodySize }
                }
                TokenChart {
                    id: chart
                    stacked: true
                    days: page.usage ? page.usage.days : []
                    chartHeight: 56
                }
                AsbText {
                    readonly property var d: chart.shown
                    text: d ? d.label + "：" + d.costText + " · " + d.tokensText : ""
                    strong: true
                }
                Repeater {
                    model: chart.shown ? chart.shown.models : []
                    RowLayout {
                        required property var modelData
                        spacing: 8
                        Rectangle { width: 3; Layout.fillHeight: true; radius: 1.5; color: modelData.color }
                        ColumnLayout {
                            spacing: 1
                            AsbText { text: modelData.name; caption: true; strong: true }
                            AsbText {
                                text: modelData.costText + " · " + modelData.tokensText + " · " + modelData.share + "%"
                                caption: true
                                secondary: true
                            }
                        }
                    }
                }
            }
        }
        AsbText {
            visible: text.length > 0
            text: page.usage ? (page.usage.empty || "") : ""
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbText {
            visible: text.length > 0
            text: App.liveData ? (App.usage.rateNote || "") : ""
            caption: true
            color: Theme.tertiary
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }

    // Projects and sessions (CodexUsageDetails.projects / buildClaudeUsageDetails).
    AsbSection {
        visible: page.usage !== null && page.usage.projects.length > 0
        title: Theme.t("项目与会话 · 近 30 天", "Projects & Sessions · 30 days")
        footer: page.claude
            ? Theme.t("本机 Claude Code 会话日志，按项目路径汇总。", "Local Claude Code session logs by project path.")
            : Theme.t("本机 Codex 会话日志，按项目路径汇总；不归属于当前所选账号。", "Local Codex session logs by project path; not attributed to the selected account.")
        Repeater {
            model: page.usage ? page.usage.projects : []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    AsbText { text: modelData.name; strong: true; Layout.fillWidth: true }
                    AsbText { text: modelData.cost; strong: true }
                }
                AsbText {
                    text: modelData.sessions + Theme.t(" 个会话 · ", " sessions · ") + modelData.tokens + Theme.t(" token", " tokens")
                    caption: true
                    secondary: true
                }
                AsbMeter { fraction: modelData.share; barHeight: 4 }
            }
        }
    }
}
