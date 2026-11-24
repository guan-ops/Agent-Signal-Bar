import QtQuick
import QtQuick.Layouts
import AgentSignal

// Segmented control. `options` is [{value, label}]; binds to App.prefs[key] when key is set.
Rectangle {
    id: root
    property var options: []
    property string key
    property var value: key.length > 0 ? App.prefs[key] : undefined
    property int segmentWidth: 66
    signal activated(var value)

    implicitWidth: row.implicitWidth + 4
    implicitHeight: 24
    radius: Theme.radiusControl
    color: Theme.controlBg
    border.color: Theme.controlStroke

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 2
        spacing: 0
        Repeater {
            model: root.options
            Rectangle {
                required property var modelData
                readonly property bool selected: modelData.value === root.value
                Layout.preferredWidth: Math.max(root.segmentWidth, segmentLabel.implicitWidth + 20)
                Layout.fillHeight: true
                radius: Theme.radiusControl - 1
                color: selected ? Theme.accent : (hover.containsMouse ? Theme.hoverFill : "transparent")
                AsbText {
                    id: segmentLabel
                    anchors.centerIn: parent
                    text: modelData.label
                    strong: parent.selected
                    color: parent.selected ? Theme.textOnAccent : Theme.text
                }
                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (root.key.length > 0) App.prefs[root.key] = modelData.value
                        root.activated(modelData.value)
                    }
                }
            }
        }
    }
}
