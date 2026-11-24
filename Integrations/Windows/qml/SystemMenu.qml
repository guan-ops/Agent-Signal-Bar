import QtQuick
import QtQuick.Layouts
import AgentSignal

// System menu mode: the usage card followed by menu items (the macOS native NSMenu).
PopupWindow {
    id: menu
    title: "Agent Signal Bar"
    padding: 6
    placement: "menu"

    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: 6
        spacing: 2
        RowLayout {
            spacing: 7
            Rectangle {
                width: 9
                height: 9
                radius: 4.5
                color: Theme.toneLamp(Theme.toneForState(App.displayState))
            }
            AsbText {
                text: "Agent Signal Bar"
                font.pixelSize: 14
                secondary: true
            }
        }
        AsbText {
            text: Theme.stateTitle(App.displayState) + " · " + Theme.stateAction(App.displayState)
            font.pixelSize: 14
            color: Theme.tertiary
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    UsageCard {
        Layout.margins: 6
        nativeMenu: true
        onOpenSettings: {
            menu.hide()
            App.openSettings("usage")
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    MenuRow {
        title: Theme.t("切换账号", "Switch account")
        showChevron: true
        onClicked: {
            menu.hide()
            App.openSettings("usage")
        }
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    MenuRow {
        icon: "terminal"
        title: Theme.t("打开 Codex", "Open Codex")
        onClicked: App.openUrl("https://chatgpt.com/codex")
    }
    MenuRow {
        icon: App.paused ? "play" : "pause"
        title: App.paused ? Theme.t("继续监控", "Resume Monitoring") : Theme.t("暂停监控", "Pause Monitoring")
        onClicked: App.togglePause()
    }
    MenuRow {
        icon: App.prefs.floatingEnabled ? "eyeOff" : "eye"
        title: App.prefs.floatingEnabled ? Theme.t("隐藏悬浮灯", "Hide Floating Signal") : Theme.t("显示悬浮灯", "Show Floating Signal")
        onClicked: App.prefs.floatingEnabled = !App.prefs.floatingEnabled
    }
    MenuRow {
        icon: App.prefs.soundEnabled ? "mute" : "speaker"
        title: App.prefs.soundEnabled ? Theme.t("关闭声音提醒", "Turn Sound Off") : Theme.t("开启声音提醒", "Turn Sound On")
        onClicked: App.prefs.soundEnabled = !App.prefs.soundEnabled
    }
    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
    // CodexBar's menu: "Check for Updates…", or "Update ready, restart now?" once one is downloaded.
    MenuRow {
        readonly property string stage: App.update.stage || "idle"
        icon: stage === "ready" || stage === "available" ? "download" : "refresh"
        title: stage === "ready" ? Theme.t("更新已就绪，立即重启？", "Update ready, restart now?")
            : stage === "available" ? Theme.t("有新版本 ", "Update available: ") + (App.update.latest || "") + "…"
            : stage === "downloading" || stage === "verifying" ? Theme.t("正在下载更新…", "Downloading update…")
            : Theme.t("检查更新…", "Check for Updates…")
        onClicked: {
            menu.hide()
            if (stage === "idle" || stage === "upToDate" || stage === "failed") App.checkForUpdates()
            else App.showUpdate()
        }
    }
    MenuRow {
        icon: "gear"
        title: Theme.t("设置", "Settings")
        onClicked: {
            menu.hide()
            App.openSettings("")
        }
    }
    MenuRow {
        icon: "power"
        title: Theme.t("退出", "Quit")
        onClicked: App.quit()
    }
}
