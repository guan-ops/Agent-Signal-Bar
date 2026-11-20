import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// 用量 / Usage: account, quota windows, reset credits, token usage, projects.
SettingsPage {
    id: page
    readonly property var account: Demo.account(Theme.t)
    readonly property var days: Demo.days(Theme.t)
    readonly property bool claude: App.prefs.usagePlatform === "claude"

    RowLayout {
        Layout.fillWidth: true
        AsbText {
            text: Theme.t("用量", "Usage")
            font.pixelSize: Theme.titleSize
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        StatusPill {
            visible: App.liveData
            text: Theme.t("演示数据", "Demo data")
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
                Icon { anchors.centerIn: parent; name: "person"; size: 18; color: "white" }
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

    // Token usage.
    AsbSection {
        visible: !page.claude
        title: Theme.t("Token 使用", "Token Usage")
        AsbText {
            text: Theme.t("本机 Codex 会话汇总，不归属于当前所选账号。", "Local Codex sessions, not attributed to the selected account.")
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            spacing: 5
            Icon { name: "check"; size: 12; color: Theme.secondary }
            AsbText { text: page.account.scan; caption: true; secondary: true }
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
                    AsbStat { label: Theme.t("今日", "Today"); value: "$7.32"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天费用", "30-day cost"); value: "$190.99"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("今日 token 用量", "Today's tokens"); value: Theme.t("131.68万 token", "1.32M tokens"); valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天 token 用量", "30-day tokens"); value: Theme.t("3,437.79万 token", "34.38M tokens"); valueSize: Theme.bodySize }
                }
                TokenChart {
                    id: chart
                    stacked: true
                    days: page.days
                    chartHeight: 56
                }
                AsbText {
                    readonly property var d: chart.shown
                    text: d ? d.label + "：$" + (d.models[0].cost + d.models[1].cost).toFixed(2) + " · "
                              + (App.language === "zh" ? (d.total * 100).toFixed(2) + "万 token" : d.total.toFixed(2) + "M tokens") : ""
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
                                text: "$" + modelData.cost.toFixed(2) + " · "
                                      + (App.language === "zh" ? (modelData.tokens * 100).toFixed(2) + "万 token" : modelData.tokens.toFixed(2) + "M tokens")
                                      + " · " + Math.round(100 * modelData.tokens / chart.shown.total) + "%"
                                caption: true
                                secondary: true
                            }
                        }
                    }
                }
            }
        }
    }

    // Projects and sessions.
    AsbSection {
        visible: !page.claude
        title: Theme.t("项目与会话 · 近 30 天", "Projects & Sessions · 30 days")
        footer: Theme.t("本机 Codex 会话日志，按项目路径汇总；不归属于当前所选账号。", "Local Codex session logs by project path; not attributed to the selected account.")
        Repeater {
            model: Demo.projects(Theme.t)
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
