import QtQuick
import QtQuick.Layouts

// ASBMenuRow: a row that behaves like a menu item (accent highlight on hover).
Rectangle {
    id: root
    property string title
    property string shortcut
    property string icon
    property bool showChevron: false
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: 26
    radius: 5
    color: mouse.containsMouse ? Theme.accent : "transparent"

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.s
        anchors.rightMargin: Theme.s
        spacing: Theme.s
        Icon {
            visible: root.icon.length > 0
            name: root.icon
            size: 15
            color: mouse.containsMouse ? "white" : Theme.text
        }
        AsbText {
            text: root.title
            color: mouse.containsMouse ? "white" : Theme.text
            Layout.fillWidth: true
        }
        AsbText {
            visible: root.shortcut.length > 0
            text: root.shortcut
            color: mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.85) : Theme.secondary
        }
        Icon {
            visible: root.showChevron
            name: "chevronRight"
            size: 13
            color: mouse.containsMouse ? "white" : Theme.secondary
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
