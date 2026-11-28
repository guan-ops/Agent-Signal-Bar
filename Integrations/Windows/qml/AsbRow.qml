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
        // Text.Wrap, not WordWrap: a long path or URL has no spaces, and WordWrap let it run past
        // the window and under the trailing control (Install CLI shows the app folder).
        AsbText {
            text: root.title
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        AsbText {
            visible: root.subtitle.length > 0
            text: root.subtitle
            caption: true
            secondary: true
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
    // A Row, so several trailing controls (Show + Export…) sit side by side instead of on top of each other.
    Row {
        id: trailingSlot
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        spacing: Theme.s
    }
}
