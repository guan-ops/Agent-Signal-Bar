import QtQuick

// Stroke icon drawn from a 24×24 path, standing in for the SF Symbols the macOS app uses.
Item {
    id: root
    property string name
    property color color: Theme.text
    property real size: 16
    property real strokeWidth: 1.9

    readonly property var paths: ({
        "activity": "M3 12h4l3-8 4 16 3-8h4",
        "chart": "M5 20V11 M10 20V5 M15 20v-8 M20 20v-4",
        "bulb": "M9 18h6 M10 21h4 M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z",
        "link": "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1 M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
        "gear": "M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z M12 2v3 M12 19v3 M4.9 4.9l2.1 2.1 M17 17l2.1 2.1 M2 12h3 M19 12h3 M4.9 19.1L7 17 M17 7l2.1-2.1",
        "info": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 11v6 M12 7.5v.5",
        "debug": "M6 3v6a4 4 0 0 0 8 0V3 M10 13v3a5 5 0 0 0 10 0v-2 M20 10.5a1.5 1.5 0 1 0 0 3a1.5 1.5 0 1 0 0-3z",
        "refresh": "M20 11a8 8 0 1 0-2.3 5.7 M20 4v7h-7",
        "pause": "M8 5v14 M16 5v14",
        "play": "M7 5l12 7-12 7z",
        "power": "M12 3v9 M6.3 6.3a8 8 0 1 0 11.4 0",
        "terminal": "M4 5h16v14H4z M7.5 9.5l3 2.5-3 2.5 M12.5 15h4",
        "eye": "M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6z",
        "eyeOff": "M3 3l18 18 M10.6 5.1A10 10 0 0 1 12 5c6 0 10 7 10 7a17 17 0 0 1-3.2 3.9 M6.6 6.6A17 17 0 0 0 2 12s4 7 10 7a9.7 9.7 0 0 0 5.4-1.6 M9.9 9.9a3 3 0 0 0 4.2 4.2",
        "mute": "M11 5L6 9H3v6h3l5 4z M22 9l-6 6 M16 9l6 6",
        "speaker": "M11 5L6 9H3v6h3l5 4z M15.5 8.5a5 5 0 0 1 0 7 M18.5 5.5a9 9 0 0 1 0 13",
        "chevronRight": "M9 6l6 6-6 6",
        "chevronDown": "M6 9l6 6 6-6",
        "person": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 7a3 3 0 1 0 0 6a3 3 0 1 0 0-6z M6.5 18a6 6 0 0 1 11 0",
        "personAdd": "M10 4a4 4 0 1 0 0 8a4 4 0 1 0 0-8z M3 21a7 7 0 0 1 14 0 M19 8v6 M16 11h6",
        "clock": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 7v5l3 2",
        "check": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M8 12l3 3 5-6",
        "live": "M12 12v.01 M8.5 8.5a5 5 0 0 0 0 7 M15.5 8.5a5 5 0 0 1 0 7 M5.6 5.6a9 9 0 0 0 0 12.8 M18.4 5.6a9 9 0 0 1 0 12.8",
        "ellipsis": "M6 12h.01 M12 12h.01 M18 12h.01",
        "copy": "M8 8h12v12H8z M4 16V4h12",
        "sparkles": "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z",
        "folder": "M3 6h6l2 2h10v11H3z",
        "download": "M12 3v12 M7 10l5 5 5-5 M4 21h16",
        "external": "M7 17L17 7 M8 7h9v9",
        "resize": "M20 14v6h-6 M20 20l-7-7"
    })

    function svgColor(c) {
        return "rgb(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + ")"
    }

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        sourceSize: Qt.size(root.size * 3, root.size * 3)
        smooth: true
        source: root.name.length === 0 ? "" : "data:image/svg+xml;utf8," + encodeURIComponent(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="' + root.svgColor(root.color)
            + '" stroke-opacity="' + root.color.a + '" stroke-width="' + (root.name === "ellipsis" ? 3.2 : root.strokeWidth)
            + '" stroke-linecap="round" stroke-linejoin="round"><path d="' + (root.paths[root.name] || "") + '"/></svg>')
    }
}
