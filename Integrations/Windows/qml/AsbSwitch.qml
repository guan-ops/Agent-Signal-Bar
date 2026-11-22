import QtQuick

// The settings switch (macOS-style mini toggle, accent when on).
Item {
    id: root
    property bool checked: false
    signal toggled(bool checked)
    implicitWidth: 32
    implicitHeight: 18

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Theme.accent : Theme.track
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    Rectangle {
        width: parent.height - 4
        height: width
        radius: width / 2
        y: 2
        x: root.checked ? parent.width - width - 2 : 2
        color: root.checked ? Theme.textOnAccent : "white" // a white knob vanishes on a light accent
        border.color: Qt.rgba(0, 0, 0, 0.08)
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
