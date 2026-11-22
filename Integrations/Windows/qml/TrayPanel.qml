import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// Card panel menu mode (MenuBarPanelView, 1.7.0): state header with pause button,
// up to three sessions, the usage summary, then Settings… and Quit rows.
PopupWindow {
    id: panel
    title: "Agent Signal Bar"
    padding: 16

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        TrafficSignal {
            layout: "horizontal"
            diameter: 12
            padX: 5
            padY: 5
        }
        ColumnLayout {
            spacing: 1
            Layout.fillWidth: true
            AsbText { text: Theme.stateTitle(App.displayState); strong: true; Layout.fillWidth: true }
            AsbText {
                text: App.paused ? Theme.t("监控已暂停", "Monitoring paused") : Theme.t("自动跟随", "Auto Follow")
                caption: true
                secondary: true
            }
        }
        Rectangle {
            width: 26
            height: 26
            radius: Theme.radiusControl
            color: pauseArea.containsMouse ? Theme.hoverFill : (Theme.dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.07))
            Icon { anchors.centerIn: parent; name: App.paused ? "play" : "pause"; size: 12 }
            MouseArea {
                id: pauseArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: App.togglePause()
            }
        }
    }
    ColumnLayout {
        visible: !App.paused
        Layout.fillWidth: true
        spacing: 2
        // SessionRowView: dot, "Codex · 终端运行中 · 思考中", time; tinted when it needs you.
        Repeater {
            model: (App.liveData ? App.sessions : Demo.sessions(Theme.t)).slice(0, 3)
            Rectangle {
                id: row
                required property var modelData
                readonly property string tone: Theme.toneForState(modelData.state)
                Layout.fillWidth: true
                implicitHeight: rowContent.implicitHeight + 10
                radius: 7
                color: tone === "critical" || tone === "caution"
                    ? Qt.rgba(Theme.toneLamp(tone).r, Theme.toneLamp(tone).g, Theme.toneLamp(tone).b, 0.12) : "transparent"
                RowLayout {
                    id: rowContent
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s
                    anchors.rightMargin: Theme.s
                    spacing: Theme.s
                    Rectangle { width: 8; height: 8; radius: 4; color: Theme.toneLamp(row.tone) }
                    // Plain text only: tool names come from log files.
                    RowLayout {
                        spacing: 4
                        Layout.fillWidth: true
                        AsbText { text: row.modelData.title; strong: true; textFormat: Text.PlainText; elide: Text.ElideNone }
                        AsbText {
                            text: "· " + row.modelData.detail
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                        }
                    }
                    AsbText { text: row.modelData.time; caption: true; secondary: true }
                }
            }
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    UsageCard {
        onOpenSettings: {
            panel.hide()
            App.openSettings("usage")
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: -Theme.s
        Layout.rightMargin: -Theme.s
        spacing: 0
        MenuRow {
            title: Theme.t("设置…", "Settings…")
            shortcut: "Ctrl+,"
            onClicked: {
                panel.hide()
                App.openSettings("")
            }
        }
        MenuRow {
            title: Theme.t("退出 Agent Signal Bar", "Quit Agent Signal Bar")
            shortcut: "Ctrl+Q"
            onClicked: App.quit()
        }
    }

    // The shortcuts the two rows above show.
    Shortcut {
        sequence: "Ctrl+,"
        onActivated: {
            panel.hide()
            App.openSettings("")
        }
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: App.quit()
    }
}
