import QtQuick
import QtQuick.Layouts

// Bordered push button; `prominent` fills with the accent.
Rectangle {
    id: root
    property string text
    property string icon
    property bool prominent: false
    property bool large: false
    signal clicked()

    implicitWidth: row.implicitWidth + (large ? 28 : 18)
    implicitHeight: large ? 36 : 26
    radius: large ? 8 : Theme.radiusControl
    color: prominent ? Theme.accent : (mouse.pressed ? Theme.hoverFill : (mouse.containsMouse ? Qt.lighter(Theme.controlBg, 1.2) : Theme.controlBg))
    border.color: prominent ? "transparent" : Theme.controlStroke

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Icon {
            visible: root.icon.length > 0
            name: root.icon
            size: root.large ? 16 : 13
            color: root.prominent ? "white" : Theme.text
        }
        AsbText {
            text: root.text
            strong: true
            font.pixelSize: root.large ? 14 : Theme.bodySize
            color: root.prominent ? "white" : Theme.text
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
