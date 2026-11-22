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

    // Drawn inside the settings window: as a separate Popup.Window (Qt 6.8, Windows) the list
    // received mouse moves but never the press, so no option could be picked. The margins keep a
    // list near the bottom of the window inside it.
    Popup {
        id: popup
        popupType: Popup.Item
        margins: Theme.s
        focus: true // takes keyboard focus when open, so Esc closes it
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
                ItemDelegate {
                    id: option
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 26
                    hoverEnabled: true
                    padding: 0
                    leftPadding: Theme.s
                    rightPadding: Theme.s
                    contentItem: AsbText {
                        text: (option.modelData.value === root.value ? "✓  " : "     ") + option.modelData.label
                        color: option.hovered ? Theme.textOnAccent : Theme.text
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: 5
                        color: option.hovered ? Theme.accent : "transparent"
                    }
                    onClicked: {
                        // Close first: a new language relabels the options, the Repeater rebuilds
                        // them and destroys this one before a later close() could run.
                        const value = option.modelData.value
                        popup.close()
                        if (root.key.length > 0) App.prefs[root.key] = value
                        root.activated(value)
                    }
                }
            }
        }
    }
}
