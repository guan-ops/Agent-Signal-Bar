import QtQuick
import QtQuick.Layouts

// ASBGroup: the raised box of a grouped form. Children stack vertically.
Rectangle {
    id: root
    default property alias content: column.data
    property int padding: Theme.m
    property alias spacing: column.spacing

    Layout.fillWidth: true
    implicitHeight: column.implicitHeight + padding * 2
    radius: Theme.radiusGroup
    color: Theme.groupFill
    border.color: Theme.groupStroke
    border.width: 1

    ColumnLayout {
        id: column
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        spacing: 10
    }
}
