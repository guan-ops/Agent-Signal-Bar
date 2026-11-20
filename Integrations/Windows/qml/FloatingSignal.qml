import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import AgentSignal
import "DemoData.js" as Demo

// FloatingSignalWindowController: an always-on-top, draggable, resizable desktop lamp
// with corner badges (quota, running agents, tokens) and a click popover.
Window {
    id: win
    readonly property bool vertical: App.prefs.floatingLayout !== "horizontal"
    readonly property real visualScale: {
        switch (App.prefs.floatingSize) {
        case "compact": return 1.15
        case "large": return 1.95
        case "custom": return Math.min(2.6, Math.max(0.85, App.prefs.floatingScale))
        default: return 1.5
        }
    }
    readonly property int badgeInset: 14
    readonly property alias popoverWindow: popover
    function showContextMenu() { contextMenu.popup() }

    title: "Agent Signal Bar Floating Light"
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    width: lamp.implicitWidth + badgeInset * 2
    height: lamp.implicitHeight + badgeInset * 2

    function placeDefault() {
        const p = App.floatingPosition(App.prefs.floatingX, App.prefs.floatingY, width, height)
        x = p.x
        y = p.y
    }
    Component.onCompleted: placeDefault()
    onXChanged: saveTimer.restart()
    onYChanged: saveTimer.restart()
    Timer {
        id: saveTimer
        interval: 400
        onTriggered: if (win.visible && App.captureDir.length === 0) {
            App.prefs.floatingX = win.x
            App.prefs.floatingY = win.y
        }
    }

    TrafficSignal {
        id: lamp
        x: win.badgeInset
        y: win.badgeInset
        layout: win.vertical ? "vertical" : "horizontal"
        diameter: 16 * win.visualScale
    }

    MouseArea {
        anchors.fill: lamp
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point pressPos
        property bool dragged: false
        onPressed: mouse => {
            pressPos = Qt.point(mouse.x, mouse.y)
            dragged = false
        }
        onPositionChanged: mouse => {
            if (!dragged && (Math.abs(mouse.x - pressPos.x) > 3 || Math.abs(mouse.y - pressPos.y) > 3)) {
                dragged = true
                win.startSystemMove()
            }
        }
        onReleased: mouse => {
            if (dragged) return
            if (mouse.button === Qt.RightButton) contextMenu.popup()
            else popover.toggle()
        }
    }

    // Corner badges.
    component Badge: Rectangle {
        property alias text: label.text
        property color textColor: Theme.text
        property bool inverted: false
        width: Math.max(height, label.implicitWidth + 8)
        height: 20
        radius: height / 2
        color: inverted ? "white" : Theme.groupFill
        border.color: Theme.groupStroke
        AsbText {
            id: label
            anchors.centerIn: parent
            font.pixelSize: Theme.badgeSize
            font.weight: Font.Bold
            color: parent.inverted ? "black" : parent.textColor
        }
    }
    Badge {
        visible: App.prefs.badgeQuota
        x: 0
        y: 0
        text: "76%"
        textColor: Theme.toneForeground("positive")
    }
    Badge {
        visible: App.prefs.badgeRunning
        x: win.width - width
        y: 0
        text: "1"
        inverted: true
    }
    Badge {
        visible: App.prefs.badgeToken
        x: 0
        y: win.height - height
        text: "1.3M"
        textColor: Theme.accent
    }
    // Free resize handle (bottom-right arrow): switches the size to "custom".
    Icon {
        name: "resize"
        size: 12
        color: Qt.rgba(1, 1, 1, resizeArea.containsMouse ? 0.9 : 0.35)
        x: lamp.x + lamp.width - 13
        y: lamp.y + lamp.height - 13
        MouseArea {
            id: resizeArea
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.SizeFDiagCursor
            property real startX
            property real startScale
            onPressed: mouse => {
                startX = mapToGlobal(mouse.x, mouse.y).x
                startScale = win.visualScale
            }
            onPositionChanged: mouse => {
                if (!pressed) return
                const dx = mapToGlobal(mouse.x, mouse.y).x - startX
                App.prefs.floatingSize = "custom"
                App.prefs.floatingScale = Math.min(2.6, Math.max(0.85, startScale + dx / 60))
            }
        }
    }

    Menu {
        id: contextMenu
        popupType: Popup.Window
        MenuItem { text: Theme.t("小", "Small"); onTriggered: App.prefs.floatingSize = "compact" }
        MenuItem { text: Theme.t("默认", "Default"); onTriggered: App.prefs.floatingSize = "standard" }
        MenuItem { text: Theme.t("大", "Large"); onTriggered: App.prefs.floatingSize = "large" }
        MenuSeparator {}
        MenuItem {
            text: win.vertical ? Theme.t("切换为横向", "Horizontal") : Theme.t("切换为竖向", "Vertical")
            onTriggered: App.prefs.floatingLayout = win.vertical ? "horizontal" : "vertical"
        }
        MenuItem { text: Theme.t("设置...", "Settings..."); onTriggered: App.openSettings("light") }
        MenuItem { text: Theme.t("隐藏悬浮灯", "Hide Floating Light"); onTriggered: App.prefs.floatingEnabled = false }
    }

    // Compact session & usage popover (ClaudeFloatingQuotaPopoverView / floating usage).
    Window {
        id: popover
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "transparent"
        width: 280
        height: pop.implicitHeight
        function toggle() {
            if (visible) { hide(); return }
            x = win.x + win.width + 6 + width > Screen.desktopAvailableWidth ? win.x - width - 6 : win.x + win.width + 6
            y = Math.max(8, win.y)
            show()
            requestActivate()
        }
        onActiveChanged: if (!active && visible && App.captureDir.length === 0) hide()
        Rectangle {
            id: pop
            anchors.fill: parent
            implicitHeight: col.implicitHeight + Theme.m * 2
            radius: Theme.radiusPanel
            color: Theme.panelBg
            border.color: Theme.panelStroke
            ColumnLayout {
                id: col
                x: Theme.m
                y: Theme.m
                width: parent.width - Theme.m * 2
                spacing: Theme.s
                RowLayout {
                    StatusPill { text: Theme.stateTitle(App.displayState); tone: Theme.toneForState(App.displayState) }
                    AsbText { text: Theme.stateAction(App.displayState); caption: true; secondary: true }
                }
                Repeater {
                    model: Demo.sessions(Theme.t)
                    RowLayout {
                        required property var modelData
                        Rectangle { width: 7; height: 7; radius: 3.5; color: Theme.lampGreen }
                        AsbText { text: modelData.agent; strong: true }
                        AsbText { text: modelData.detail; secondary: true; Layout.fillWidth: true }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
                Repeater {
                    model: Demo.account(Theme.t).quotas
                    QuotaLine {
                        required property var modelData
                        compact: true
                        title: modelData.title
                        valueText: modelData.remaining + "%"
                        remainingPercent: modelData.remaining
                        detail: modelData.reset
                    }
                }
            }
        }
    }
}
