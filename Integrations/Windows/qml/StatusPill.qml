import QtQuick

// ASBStatusPill: short state label on a tinted capsule.
Rectangle {
    property alias text: label.text
    property string tone: "neutral"
    implicitWidth: label.implicitWidth + 16
    implicitHeight: label.implicitHeight + 4
    radius: height / 2
    color: Theme.toneBackground(tone)
    AsbText {
        id: label
        anchors.centerIn: parent
        caption: true
        color: Theme.toneForeground(parent.tone)
    }
}
