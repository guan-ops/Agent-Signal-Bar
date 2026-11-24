import QtQuick
import QtQuick.Layouts

// ASBSection: optional title, a raised group of rows, optional footer.
ColumnLayout {
    id: root
    default property alias content: group.content
    property string title
    property string footer
    property alias groupSpacing: group.spacing
    property alias headerAccessory: accessory.data

    Layout.fillWidth: true
    spacing: 6

    RowLayout {
        visible: root.title.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: 2
        AsbText {
            text: root.title
            strong: true
            secondary: true
            Layout.fillWidth: true
        }
        Item {
            id: accessory
            implicitWidth: childrenRect.width
            implicitHeight: childrenRect.height
        }
    }
    AsbGroup {
        id: group
    }
    AsbText {
        visible: root.footer.length > 0
        text: root.footer
        caption: true
        secondary: true
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
        Layout.leftMargin: 2
    }
}
