import QtQuick
import QtQuick.Layouts

// ASBQuotaLine: name · remaining, meter, reset time.
ColumnLayout {
    id: root
    property string title
    property string valueText
    property real remainingPercent: 0
    property string detail
    property bool compact: false
    readonly property string tone: Theme.toneForRemaining(remainingPercent)

    Layout.fillWidth: true
    spacing: compact ? 4 : 6
    RowLayout {
        Layout.fillWidth: true
        AsbText {
            text: root.title
            font.pixelSize: root.compact ? 12 : Theme.bodySize
            Layout.fillWidth: true
        }
        AsbText {
            visible: root.valueText.length > 0
            text: root.valueText
            strong: true
            font.pixelSize: root.compact ? 12 : Theme.bodySize
            color: root.tone === "accent" || root.tone === "neutral" ? Theme.text : Theme.toneForeground(root.tone)
        }
    }
    AsbMeter {
        fraction: root.remainingPercent / 100
        tone: root.tone
        barHeight: root.compact ? 5 : 6
    }
    AsbText {
        visible: root.detail.length > 0
        text: root.detail
        caption: true
        secondary: true
    }
}
