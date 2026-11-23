import QtQuick
import QtQuick.Layouts
import AgentSignal

// 关于 / About: version, update checks, download page, license line.
SettingsPage {
    AsbSection {
        title: Theme.t("关于", "About")
        AsbRow {
            title: Theme.t("版本", "Version")
            AsbText { text: App.version + " (Windows)"; secondary: true }
        }
        // Neither the switch nor the button did anything: update checks are not ported yet.
        AsbRow {
            title: Theme.t("检查更新", "Check for Updates")
            subtitle: Theme.t("Windows 版更新检查尚未接入 GitHub Releases，请用下面的下载页面获取新版本。",
                              "Windows update checks are not wired to GitHub Releases yet; get new versions from the download page below.")
            StatusPill { text: Theme.t("尚未移植", "Not ported"); tone: "neutral" }
        }
        AsbRow {
            title: Theme.t("下载", "Download")
            AsbButton {
                icon: "external"
                text: Theme.t("打开下载页面", "Open Download Page")
                onClicked: App.openUrl("https://github.com/guan-ops/Agent-Signal-Bar/releases/latest")
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
