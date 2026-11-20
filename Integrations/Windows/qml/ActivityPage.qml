import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// 运行 / Activity: current state, which agent drives the light, sessions, recent events.
SettingsPage {
    readonly property var sessionRows: App.paused ? [] : (App.liveData ? App.sessions : Demo.sessions(Theme.t))
    readonly property var eventRows: App.liveData ? App.events : Demo.events(Theme.t)
    readonly property string updatedTime: App.liveData ? (App.codexConnection.lastActivity || "") : "16:05"

    // Current state card.
    AsbGroup {
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.m
            Rectangle {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 3
                width: 12
                height: 12
                radius: 6
                color: Theme.toneLamp(Theme.toneForState(App.displayState))
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                AsbText { text: Theme.stateTitle(App.displayState); strong: true; Layout.fillWidth: true }
                AsbText { text: Theme.stateSummary(App.displayState); caption: true; secondary: true; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                AsbText {
                    visible: updatedTime.length > 0
                    text: Theme.t("更新 ", "Updated ") + updatedTime
                    caption: true
                    color: Theme.tertiary
                }
            }
            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                spacing: 3
                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: 4
                    Icon { name: "live"; size: 13; color: Theme.secondary }
                    AsbText {
                        text: App.paused ? Theme.t("监控已暂停", "Paused") : Theme.t("实时监控", "Live")
                        caption: true
                        strong: true
                        secondary: true
                    }
                }
                AsbText {
                    Layout.alignment: Qt.AlignRight
                    text: Theme.t(sessionRows.length + " 个会话",
                                  sessionRows.length === 1 ? "1 session" : sessionRows.length + " sessions")
                    caption: true
                    color: Theme.tertiary
                }
            }
        }
    }

    AsbSection {
        title: Theme.t("灯效 Agent", "Light Agent")
        AsbRow {
            title: Theme.t("跟随", "Follow")
            subtitle: Theme.t("灯效跟随最活跃的 Agent", "The light follows the most active agent")
            Dropdown {
                key: "lightAgentMode"
                pickerWidth: 150
                options: [
                    { value: "following", label: Theme.t("自动", "Automatic") },
                    { value: "codex", label: "Codex" },
                    { value: "codexDesktop", label: Theme.t("Codex 桌面版", "Codex Desktop") },
                    { value: "codexCLI", label: Theme.t("Codex 终端", "Codex CLI") },
                    { value: "codexVSCode", label: "Codex VS Code" },
                    { value: "codexIDEA", label: "Codex IDEA" },
                    { value: "claude", label: "Claude" },
                    { value: "localScript", label: Theme.t("本地脚本", "Local Script") }
                ]
            }
        }
        AsbRow {
            title: Theme.t("空闲时显示其他 Agent", "Show Others While Idle")
            subtitle: Theme.t("已选 Agent 没在工作时，灯效暂时显示正在工作的其他 Agent", "When the selected agent is idle, the light shows another working agent")
            PrefSwitch { key: "showOtherAgentsWhenIdle" }
        }
    }

    AsbSection {
        title: Theme.t("正在运行", "Running")
        Repeater {
            model: sessionRows
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 5
                    width: 7
                    height: 7
                    radius: 3.5
                    color: Theme.toneLamp(Theme.toneForState(modelData.state))
                }
                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    RowLayout {
                        Layout.fillWidth: true
                        AsbText { text: modelData.agent; strong: true; textFormat: Text.PlainText }
                        StatusPill { text: modelData.pill; tone: Theme.toneForState(modelData.state) }
                        Item { Layout.fillWidth: true }
                        AsbText { text: modelData.time; caption: true; color: Theme.tertiary }
                    }
                    AsbText { text: modelData.detail; caption: true; secondary: true; textFormat: Text.PlainText; Layout.fillWidth: true }
                }
            }
        }
        ColumnLayout {
            visible: sessionRows.length === 0
            spacing: 2
            AsbText { text: Theme.t("当前没有正在工作的 Agent", "No agent is working"); secondary: true }
            AsbText { text: Theme.t("空闲时不会点亮状态栏和悬浮信号灯。", "Idle agents do not light the tray or the floating signal."); caption: true; color: Theme.tertiary }
        }
    }

    AsbSection {
        title: Theme.t("最近事件", "Recent Events")
        Repeater {
            model: eventRows
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 5
                    width: 7
                    height: 7
                    radius: 3.5
                    color: Theme.toneLamp(Theme.toneForState(modelData.state))
                }
                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    AsbText { text: modelData.title; strong: true; textFormat: Text.PlainText; Layout.fillWidth: true }
                    AsbText { text: modelData.detail; caption: true; secondary: true; textFormat: Text.PlainText; Layout.fillWidth: true }
                }
                AsbText { text: modelData.time; caption: true; color: Theme.tertiary; Layout.alignment: Qt.AlignTop }
            }
        }
    }
}
