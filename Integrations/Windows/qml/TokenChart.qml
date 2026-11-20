import QtQuick
import QtQuick.Layouts

// 30-day token bars. Menu style: single accent bars. Settings style: bars stacked by
// model color with a hover detail (day · cost · tokens, per-model share).
ColumnLayout {
    id: root
    property var days: []
    property bool stacked: false
    property int chartHeight: 52
    property int hovered: -1
    readonly property real peak: {
        let p = 0
        for (let i = 0; i < days.length; ++i) p = Math.max(p, days[i].total)
        return p
    }
    readonly property var shown: days.length === 0 ? null : days[hovered >= 0 ? hovered : days.length - 1]

    Layout.fillWidth: true
    spacing: 6

    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: root.chartHeight
        Row {
            id: bars
            anchors.fill: parent
            spacing: 3
            readonly property real barWidth: (width - spacing * (root.days.length - 1)) / Math.max(1, root.days.length)
            Repeater {
                model: root.days
                Item {
                    required property var modelData
                    required property int index
                    width: bars.barWidth
                    height: bars.height
                    readonly property real h: Math.max(2, bars.height * modelData.total / Math.max(0.0001, root.peak))
                    // Menu style.
                    Rectangle {
                        visible: !root.stacked
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: parent.h
                        radius: 2
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, root.hovered === index ? 1 : 0.72)
                    }
                    // Settings style: stacked by model, newest model on top.
                    Column {
                        visible: root.stacked
                        anchors.bottom: parent.bottom
                        width: parent.width
                        Repeater {
                            model: parent.parent.modelData.models
                            Rectangle {
                                required property var modelData
                                width: parent.width
                                height: parent.parent.h * modelData.tokens / Math.max(0.0001, parent.parent.modelData.total)
                                color: modelData.color
                                opacity: root.hovered === parent.parent.index ? 1 : 0.8
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.hovered = index
                        onExited: if (root.hovered === index) root.hovered = -1
                    }
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        AsbText {
            text: root.days.length > 0 ? root.days[0].label : ""
            caption: true
            secondary: true
            Layout.fillWidth: true
        }
        AsbText {
            text: root.days.length > 0 ? root.days[root.days.length - 1].label : ""
            caption: true
            secondary: true
        }
    }
}
