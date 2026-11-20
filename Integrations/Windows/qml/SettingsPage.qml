import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Scrolling page body for one settings tab; sections stack with 20 px gaps.
Flickable {
    id: root
    default property alias content: column.data
    property string title

    clip: true
    contentWidth: width
    contentHeight: column.implicitHeight + 36
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    ColumnLayout {
        id: column
        x: 18
        y: 18
        width: root.width - 36
        spacing: 20
        AsbText {
            visible: root.title.length > 0
            text: root.title
            font.pixelSize: Theme.titleSize
            font.weight: Font.DemiBold
        }
    }
}
