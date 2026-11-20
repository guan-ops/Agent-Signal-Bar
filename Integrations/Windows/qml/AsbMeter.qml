import QtQuick
import QtQuick.Layouts

// ASBMeter: quota/progress capsule whose fill follows the tone.
Item {
    property real fraction: 0
    property string tone: "accent"
    property int barHeight: 6
    Layout.fillWidth: true
    implicitHeight: barHeight
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.track
    }
    Rectangle {
        readonly property real f: Math.min(1, Math.max(0, parent.fraction))
        height: parent.height
        width: Math.max(f > 0 ? parent.barHeight : 0, parent.width * f)
        radius: height / 2
        color: Theme.toneLamp(parent.tone)
    }
}
