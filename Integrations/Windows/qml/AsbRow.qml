import QtQuick
import QtQuick.Layouts

// ASBRow: title, optional explanation, trailing control.
RowLayout {
    id: root
    property string title
    property string subtitle
    default property alias trailing: trailingSlot.data

    Layout.fillWidth: true
    Layout.minimumHeight: 24
    spacing: Theme.m

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        AsbText {
            text: root.title
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbText {
            visible: root.subtitle.length > 0
            text: root.subtitle
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }
    Item {
        id: trailingSlot
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        implicitWidth: childrenRect.width
        implicitHeight: childrenRect.height
    }
}
