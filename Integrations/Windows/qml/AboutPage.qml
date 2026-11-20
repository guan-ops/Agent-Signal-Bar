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
        AsbRow {
            title: Theme.t("自动检查更新", "Check for updates automatically")
            PrefSwitch { key: "autoUpdateCheck" }
        }
        AsbRow {
            title: Theme.t("更新", "Updates")
            subtitle: Theme.t("Windows 版更新检查尚未接入 GitHub Releases。", "Windows update checks are not wired to GitHub Releases yet.")
            AsbButton { icon: "refresh"; text: Theme.t("检查更新", "Check for Updates") }
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
