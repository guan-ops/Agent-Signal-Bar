import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import AgentSignal

// Pop-up picker styled like the macOS settings dropdowns. `options` is [{value, label}].
Item {
    id: root
    property var options: []
    property string key
    property var value: key.length > 0 ? App.prefs[key] : undefined
    property string icon
    property int pickerWidth: 136
    signal activated(var value)

    readonly property string currentLabel: {
        for (let i = 0; i < options.length; ++i) if (options[i].value === value) return options[i].label
        return options.length > 0 ? options[0].label : ""
    }

    implicitWidth: pickerWidth
    implicitHeight: 26

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusControl
        color: area.containsMouse ? Qt.lighter(Theme.controlBg, 1.15) : Theme.controlBg
        border.color: Theme.controlStroke
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 9
            anchors.rightMargin: 7
            spacing: 6
            Icon {
                visible: root.icon.length > 0
                name: root.icon
                size: 13
            }
            AsbText {
                text: root.currentLabel
                strong: true
                Layout.fillWidth: true
            }
            Icon {
                name: "chevronDown"
                size: 12
                color: Theme.secondary
            }
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            onClicked: popup.open()
        }
    }

    Popup {
        id: popup
        popupType: Popup.Window
        y: root.height + 4
        width: Math.max(root.width, 160)
        padding: 5
        background: Rectangle {
            radius: 8
            color: Theme.panelBg
            border.color: Theme.panelStroke
        }
        contentItem: ColumnLayout {
            spacing: 0
            Repeater {
                model: root.options
                MenuRow {
                    required property var modelData
                    title: (modelData.value === root.value ? "✓  " : "     ") + modelData.label
                    onClicked: {
                        if (root.key.length > 0) App.prefs[root.key] = modelData.value
                        root.activated(modelData.value)
                        popup.close()
                    }
                }
            }
        }
    }
}
