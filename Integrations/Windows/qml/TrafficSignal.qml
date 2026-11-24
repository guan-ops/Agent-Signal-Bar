import QtQuick
import AgentSignal

// TrafficSignalView: three lamps (red, yellow, green) with the same intensity, scale,
// highlight and glow rules as the macOS view. Classic style draws the black housing.
Item {
    id: root
    property string signalName: App.signalName
    property int tick: App.tick
    property string layout: "vertical"      // vertical | horizontal
    property string lampStyle: "trafficLight" // trafficLight | macOS
    property real diameter: 16
    property real spacing: diameter * (layout === "vertical" ? 5 : 8) / 16
    // FloatingSignalPreferences.signalPadding at 16 pt lamps, scaled with the diameter.
    property real padX: diameter * (vertical ? 6 : 7) / 16
    property real padY: diameter * (vertical ? 8 : 6) / 16
    property bool allLightsOn: false
    readonly property bool vertical: layout === "vertical"
    readonly property real run: diameter * 3 + spacing * 2
    readonly property string displayState: App.displayState

    implicitWidth: (vertical ? diameter : run) + padX * 2
    implicitHeight: (vertical ? run : diameter) + padY * 2

    Rectangle {
        visible: root.lampStyle === "trafficLight"
        anchors.fill: parent
        radius: 8 * root.diameter / 16
        color: Qt.rgba(0, 0, 0, 0.88)
        border.color: Qt.rgba(1, 1, 1, 0.12)
        border.width: 1
    }

    Repeater {
        model: ["red", "yellow", "green"]
        Item {
            id: lamp
            required property string modelData
            required property int index
            readonly property real intensity: App.lampIntensity(modelData, root.signalName, root.tick, root.allLightsOn)
            readonly property real lampScale: App.lampScale(modelData, root.signalName, root.tick, root.allLightsOn, root.lampStyle)
            readonly property color body: Theme.lampBody(modelData)
            readonly property real offset: index * (root.diameter + root.spacing)
            x: root.padX + (root.vertical ? 0 : offset)
            y: root.padY + (root.vertical ? offset : 0)
            width: root.diameter
            height: root.diameter

            // Base disc.
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: {
                    const s = root.displayState
                    const minimal = root.lampStyle === "macOS"
                    const g = Theme.secondary
                    if (s === "paused") return Qt.rgba(g.r, g.g, g.b, minimal ? 0.72 : 0.36)
                    if (s === "stale") return Qt.rgba(g.r, g.g, g.b, minimal ? 0.50 : 0.28)
                    return minimal ? "transparent" : Qt.rgba(g.r, g.g, g.b, 0.22)
                }
                border.width: 0.5
                border.color: root.lampStyle === "macOS" ? Qt.rgba(1, 1, 1, 0.92) : Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.10)
            }
            // Glow.
            Rectangle {
                visible: lamp.intensity > 0
                anchors.centerIn: parent
                width: parent.width * lamp.lampScale + (root.lampStyle === "macOS" ? 6 : 8)
                height: width
                radius: width / 2
                color: Qt.rgba(lamp.body.r, lamp.body.g, lamp.body.b, lamp.intensity * 0.22)
            }
            // Lit disc.
            Rectangle {
                id: lit
                visible: lamp.intensity > 0
                anchors.centerIn: parent
                width: parent.width * lamp.lampScale
                height: width
                radius: width / 2
                color: Qt.rgba(lamp.body.r, lamp.body.g, lamp.body.b, lamp.intensity)
                border.width: 0.5
                border.color: root.lampStyle === "macOS" ? color : Qt.rgba(1, 1, 1, 0.20)
                Rectangle {
                    visible: lamp.intensity > 0.7 && root.lampStyle !== "macOS"
                    x: root.diameter * 0.18 * lamp.lampScale
                    y: x
                    width: Math.max(root.diameter * 0.34, 1.5) * lamp.lampScale
                    height: width
                    radius: width / 2
                    color: Qt.rgba(1, 1, 1, 0.38)
                }
            }
        }
    }
}
