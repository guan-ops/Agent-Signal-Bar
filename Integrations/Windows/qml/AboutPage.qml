import QtQuick
import QtQuick.Layouts
import AgentSignal

// 关于 / About (developerInfoSettings): version, Sparkle-style update settings and actions,
// download page, license line.
SettingsPage {
    readonly property var u: App.update
    readonly property bool configured: u.configured === true
    readonly property string stage: u.stage || "idle"

    AsbSection {
        title: Theme.t("关于", "About")
        AsbRow {
            title: Theme.t("版本", "Version")
            AsbText { text: (u.current || App.version) + " (Windows)"; secondary: true }
        }
        AsbRow {
            title: Theme.t("自动检查更新", "Automatically check for updates")
            subtitle: configured ? Theme.t("每天检查一次 GitHub Releases，发现新版本时提示下载并重启安装。",
                                           "Checks GitHub Releases once a day and offers to download the update, then relaunch to install.")
                                 : (u.message || "")
            PrefSwitch {
                key: "SUEnableAutomaticChecks"
                enabled: configured
                opacity: enabled ? 1 : 0.45
            }
        }
        AsbRow {
            title: Theme.t("自动下载并安装更新", "Automatically download and install updates")
            subtitle: Theme.t("在后台下载并验证，退出 Agent Signal Bar 时安装。", "Downloads and verifies in the background, then installs when you quit Agent Signal Bar.")
            PrefSwitch {
                key: "SUAutomaticallyUpdate"
                // Sparkle ignores automatic downloads while automatic checks are off.
                enabled: configured && App.prefs["SUEnableAutomaticChecks"] === true
                opacity: enabled ? 1 : 0.45
            }
        }
        AsbRow {
            title: Theme.t("更新", "Updates")
            subtitle: configured ? (u.message || "") : ""
        }
        // Wraps: in English the buttons are wider than the page.
        Flow {
            Layout.fillWidth: true
            spacing: Theme.s
            AsbButton {
                visible: stage === "ready"
                prominent: true
                text: Theme.t("安装并重新启动", "Install and Relaunch")
                onClicked: App.installUpdate()
            }
            AsbButton {
                icon: "refresh"
                text: stage === "checking" ? Theme.t("正在检查…", "Checking…")
                    : stage === "available" ? Theme.t("查看新版本…", "View Update…")
                    : Theme.t("检查更新", "Check for Updates")
                enabled: stage !== "checking" && stage !== "installing"
                onClicked: stage === "available" || stage === "downloading" || stage === "verifying" ? App.showUpdate() : App.checkForUpdates()
            }
            AsbButton {
                icon: "external"
                text: Theme.t("打开下载页面", "Open Download Page")
                onClicked: App.openUrl(u.releasesPage || "https://github.com/guan-ops/Agent-Signal-Bar/releases/latest")
            }
        }
    }
    AsbText {
        text: "© 2026 XiongYang Guan · Apache License 2.0"
        caption: true
        secondary: true
        Layout.alignment: Qt.AlignHCenter
    }
}
