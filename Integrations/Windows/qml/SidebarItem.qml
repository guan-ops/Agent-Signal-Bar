import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    property string icon
    property string label
    property bool selected: false
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: 36
    radius: Theme.radiusControl
    color: selected ? Theme.accent : (mouse.containsMouse ? Theme.hoverFill : "transparent")

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        spacing: 7
        Icon {
            name: root.icon
            size: 16
            color: root.selected ? "white" : Theme.accent
        }
        AsbText {
            text: root.label
            color: root.selected ? "white" : Theme.text
            Layout.fillWidth: true
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
