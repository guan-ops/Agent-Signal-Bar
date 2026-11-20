import QtQuick
import QtQuick.Layouts

// ASBStat: label, big number, optional second line.
ColumnLayout {
    property string label
    property string value
    property string detail
    property int valueSize: Theme.valueSize
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    spacing: 2
    AsbText {
        text: parent.label
        caption: true
        secondary: true
        Layout.fillWidth: true
    }
    AsbText {
        text: parent.value
        font.pixelSize: parent.valueSize
        font.weight: Font.Bold
        font.features: { "tnum": 1 }
    }
    AsbText {
        visible: parent.detail.length > 0
        text: parent.detail
        caption: true
        strong: true
    }
}
