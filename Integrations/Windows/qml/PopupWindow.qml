import QtQuick
import QtQuick.Controls.Basic
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
    // "panel": a flyout above the taskbar; "menu": a context menu at the click point.
    property string placement: "panel"
    // At most the clicked screen's work area; taller content scrolls (1080p at 125 % or more).
    property int maxHeight: 100000
    // When focus loss last closed the popup. The tray click that caused it arrives just after
    // (the taskbar takes focus on mouse down, the icon reports the click on mouse up).
    property double autoHiddenAt: 0
    // A function, not a binding: Date.now() would never re-evaluate a binding.
    function justAutoHidden() { return Date.now() - autoHiddenAt < 500 }

    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"
    width: panelWidth
    height: Math.min(surface.implicitHeight, maxHeight)

    function place() {
        maxHeight = App.popupMaxHeight()
        const p = App.popupPosition(width, height, placement)
        x = p.x
        y = p.y
    }

    function present() {
        flick.contentY = 0
        place()
        show()
        raise()
        requestActivate()
    }

    // The content finishes its layout only after the first show, and a taller panel placed with
    // the old height would cover the taskbar: keep it anchored as it grows.
    onHeightChanged: if (visible) place()

    onActiveChanged: if (!active && visible && App.captureDir.length === 0) {
        autoHiddenAt = Date.now()
        hide()
    }

    Shortcut {
        sequence: "Esc"
        onActivated: win.hide()
    }

    Rectangle {
        id: surface
        anchors.fill: parent
        implicitHeight: column.implicitHeight + win.padding * 2
        radius: Theme.radiusPanel
        color: Theme.panelBg
        border.color: Theme.panelStroke
        border.width: 1

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: win.padding
            contentWidth: width
            contentHeight: column.implicitHeight
            clip: contentHeight > height
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            // Shown whenever the content is taller than the window (the system menu is taller than
            // a 1080p work area): AsNeeded shows the Basic style's handle only while hovering or
            // scrolling, so nothing hinted that Check for Updates, Settings and Quit lay below.
            // It sits in the right padding, 5 px wide so it fits the system menu's 6 px, clear of
            // right-aligned text. Anchored to flick (its parent before the reparenting, a sibling
            // after), as in the ScrollBar docs: anchoring to surface fails while flick is the parent.
            ScrollBar.vertical: ScrollBar {
                id: vbar
                parent: surface
                anchors.top: flick.top
                anchors.bottom: flick.bottom
                anchors.right: flick.right
                anchors.rightMargin: 1 - win.padding
                padding: 1
                policy: flick.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                // Theme colours: the Basic handle uses palette.mid, which vanishes on the dark panel.
                contentItem: Rectangle {
                    implicitWidth: 3
                    radius: 1.5
                    color: vbar.pressed || vbar.hovered ? Theme.secondary : Theme.tertiary
                }
            }

            ColumnLayout {
                id: column
                width: flick.width
                spacing: Theme.s
            }
        }
    }
}
