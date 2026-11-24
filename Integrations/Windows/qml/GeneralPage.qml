import QtQuick
import QtQuick.Layouts
import AgentSignal

// 通用 / General: appearance and language, startup, developer, command line tool.
SettingsPage {
    AsbSection {
        title: Theme.t("外观与语言", "Appearance & Language")
        AsbRow {
            title: Theme.t("语言", "Language")
            Dropdown {
                key: "language"
                options: [
                    { value: "system", label: Theme.t("跟随系统", "Follow System") },
                    { value: "zh-Hans", label: "简体中文" },
                    { value: "zh-Hant", label: "繁體中文" },
                    { value: "en", label: "English" },
                    { value: "ja", label: "日本語" },
                    { value: "ko", label: "한국어" },
                    { value: "es", label: "Español" },
                    { value: "fr", label: "Français" },
                    { value: "de", label: "Deutsch" },
                    { value: "pt", label: "Português" }
                ]
            }
        }
        AsbRow {
            title: Theme.t("主题", "Theme")
            Dropdown {
                key: "theme"
                options: [
                    { value: "system", label: Theme.t("跟随系统", "Follow System") },
                    { value: "light", label: Theme.t("浅色", "Light") },
                    { value: "dark", label: Theme.t("深色", "Dark") }
                ]
            }
        }
        AsbRow {
            title: Theme.t("费用显示货币", "Cost display currency")
            subtitle: Theme.t("今日与历史费用均按最新可用汇率估算。账号额外用量保留账单币种。",
                              "Today's and past costs use the latest available rate. Account extra usage keeps its billing currency.")
            Dropdown {
                key: "currency"
                options: ["USD", "CNY", "NZD", "EUR", "GBP", "JPY", "KRW", "CAD", "AUD", "HKD", "TWD", "SGD", "INR", "CHF", "AED", "CZK", "TRY"]
                    .map(code => ({ value: code, label: code }))
            }
        }
    }

    AsbSection {
        title: Theme.t("启动与运行", "Startup")
        AsbRow {
            title: Theme.t("开机自启动", "Start at login")
            subtitle: Theme.t("登录 Windows 后自动打开 Agent Signal Bar", "Open Agent Signal Bar when you sign in to Windows")
            PrefSwitch { key: "launchAtLogin" }
        }
        AsbRow {
            title: Theme.t("低功耗模式", "Low power mode")
            subtitle: Theme.t("降低后台轮询和动画刷新频率，适合长时间常驻。", "Reduce background polling and animation refresh while the app stays running.")
            PrefSwitch { key: "lowPowerMode" }
        }
        AsbRow {
            title: App.paused ? Theme.t("监控已暂停", "Monitoring paused") : Theme.t("实时监控", "Live monitoring")
            readonly property int sessionCount: App.liveData ? App.sessions.length : 1 // demo data shows one
            subtitle: App.paused ? "" : Theme.t(sessionCount + " 个会话", sessionCount === 1 ? "1 session" : sessionCount + " sessions")
            AsbButton {
                icon: App.paused ? "play" : "pause"
                text: App.paused ? Theme.t("恢复监控", "Resume") : Theme.t("暂停监控", "Pause")
                onClicked: App.togglePause()
            }
        }
    }

    AsbSection {
        title: Theme.t("开发者", "Developer")
        AsbRow {
            title: Theme.t("显示调试设置", "Show debug settings")
            subtitle: Theme.t("打开后会在侧边栏中显示调试页面。", "Adds a Debug page to the sidebar.")
            PrefSwitch { key: "showDebugSettings" }
        }
    }

    AsbSection {
        title: Theme.t("命令行工具", "Command Line Tool")
        AsbRow {
            title: Theme.t("安装 CLI", "Install CLI")
            subtitle: Theme.t("把 " + (App.cli.directory || "") + " 加入用户 PATH，新开的终端即可运行 agent-signal。",
                              "Adds " + (App.cli.directory || "") + " to the user PATH so new terminals can run agent-signal.")
            StatusPill {
                visible: App.cli.installed === true
                text: Theme.t("已在 PATH 中", "On PATH")
                tone: "positive"
            }
            AsbButton {
                text: App.cli.installed === true ? Theme.t("从 PATH 移除", "Remove from PATH") : Theme.t("安装", "Install")
                enabled: App.cli.canModify === true
                onClicked: App.cli.installed === true ? App.uninstallCli() : App.installCli()
            }
        }
        AsbText {
            visible: text.length > 0
            text: App.cli.message || ""
            caption: true
            color: (App.cli.tone || "neutral") === "neutral" ? Theme.secondary : Theme.toneForeground(App.cli.tone)
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            Layout.fillWidth: true
        }
    }
}
