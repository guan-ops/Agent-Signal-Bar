import QtQuick
import QtQuick.Layouts
import AgentSignal

// Claude tab of the tray panels. The Claude quota sources (Claude Code OAuth/CLI,
// claude.ai session) are not ported yet, so this shows the unconnected state.
Rectangle {
    Layout.fillWidth: true
    implicitHeight: column.implicitHeight + Theme.m * 2
    radius: Theme.radiusGroup
    color: Theme.insetTile
    border.color: Theme.groupStroke
    ColumnLayout {
        id: column
        x: Theme.m
        y: Theme.m
        width: parent.width - Theme.m * 2
        spacing: 6
        AsbText {
            text: "Claude"
            font.pixelSize: Theme.titleSize
            font.weight: Font.Bold
        }
        AsbText {
            text: Theme.t("尚未连接 Claude 额度来源。", "No Claude quota source connected.")
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbButton {
            text: Theme.t("在设置中连接", "Connect in Settings")
            onClicked: App.openSettings("usage")
        }
    }
}
