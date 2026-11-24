import QtQuick
import QtQuick.Layouts
import AgentSignal

// Codex | Claude switch with the refresh button, at the top of both tray panels.
RowLayout {
    Layout.fillWidth: true
    spacing: 6
    Segmented {
        key: "usagePlatform"
        Layout.fillWidth: true
        segmentWidth: (width - 4) / 2
        options: [{ value: "codex", label: "Codex" }, { value: "claude", label: "Claude" }]
    }
    Icon {
        name: "refresh"
        size: 14
        color: Theme.secondary
    }
}
