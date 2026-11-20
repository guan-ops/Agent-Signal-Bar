import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import AgentSignal

// A frameless panel anchored to the tray icon that closes when it loses focus,
// the Windows counterpart of the NSStatusItem popover / menu.
Window {
    id: win
    default property alias content: column.data
    property int panelWidth: 360
    property int padding: Theme.m

    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    width: panelWidth
    height: surface.implicitHeight

    function present() {
        const p = App.popupPosition(width, height)
        x = p.x
        y = p.y
        show()
        raise()
        requestActivate()
    }

    onActiveChanged: if (!active && visible && App.captureDir.length === 0) hide()

    Rectangle {
        id: surface
        anchors.fill: parent
        implicitHeight: column.implicitHeight + win.padding * 2
        radius: Theme.radiusPanel
        color: Theme.panelBg
        border.color: Theme.panelStroke
        border.width: 1

        ColumnLayout {
            id: column
            x: win.padding
            y: win.padding
            width: surface.width - win.padding * 2
            spacing: Theme.s
        }
    }
}
