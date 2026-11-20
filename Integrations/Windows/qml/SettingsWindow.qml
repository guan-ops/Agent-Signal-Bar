import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import AgentSignal

// The main settings window (DebugWindowView): lamp header, sidebar, one page per tab.
Window {
    id: win
    property string page: "activity"
    readonly property var tabs: {
        const list = [
            { id: "activity", icon: "activity", label: Theme.t("运行", "Activity") },
            { id: "usage", icon: "chart", label: Theme.t("用量", "Usage") },
            { id: "light", icon: "bulb", label: Theme.t("灯效", "Light") },
            { id: "connections", icon: "link", label: Theme.t("连接", "Connect") },
            { id: "general", icon: "gear", label: Theme.t("通用", "General") }
        ]
        if (App.prefs.showDebugSettings) list.push({ id: "debug", icon: "debug", label: Theme.t("调试", "Debug") })
        return list
    }

    title: "Agent Signal Bar"
    width: 720
    height: 700
    minimumWidth: 640
    minimumHeight: 520
    color: Theme.windowBg

    function open(pageId) {
        if (pageId && pageId.length > 0) page = pageId
        show()
        raise()
        requestActivate()
    }
    onVisibleChanged: if (visible) App.applyBackdrop(win, "window")
    Connections {
        target: App.prefs
        function onValueChanged(key) {
            if (["glassEnabled", "glassEffect", "theme"].indexOf(key) >= 0 && win.visible) App.applyBackdrop(win, "window")
        }
    }

    Shortcut {
        sequence: "Ctrl+W"
        onActivated: win.close()
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.windowBg
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header: all-lights-on lamp and the product name.
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            RowLayout {
                anchors.centerIn: parent
                spacing: 12
                TrafficSignal {
                    layout: "horizontal"
                    allLightsOn: true
                    diameter: 16
                    padX: 7
                    padY: 7
                }
                AsbText {
                    text: "Agent Signal Bar"
                    font.pixelSize: Theme.titleSize
                    font.weight: Font.DemiBold
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Sidebar.
            Rectangle {
                Layout.preferredWidth: 164
                Layout.fillHeight: true
                color: Theme.sidebarBg
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    anchors.topMargin: 16
                    spacing: 2
                    Repeater {
                        model: win.tabs
                        SidebarItem {
                            required property var modelData
                            icon: modelData.icon
                            label: modelData.label
                            selected: win.page === modelData.id
                            onClicked: win.page = modelData.id
                        }
                    }
                    Item { Layout.fillHeight: true }
                    SidebarItem {
                        icon: "info"
                        label: Theme.t("关于", "About")
                        selected: win.page === "about"
                        onClicked: win.page = "about"
                    }
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.separator }
            }

            // Content.
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.contentBg
                Loader {
                    anchors.fill: parent
                    source: {
                        switch (win.page) {
                        case "usage": return "UsagePage.qml"
                        case "light": return "LightPage.qml"
                        case "connections": return "ConnectionsPage.qml"
                        case "general": return "GeneralPage.qml"
                        case "debug": return "DebugPage.qml"
                        case "about": return "AboutPage.qml"
                        default: return "ActivityPage.qml"
                        }
                    }
                }
            }
        }
    }
}
