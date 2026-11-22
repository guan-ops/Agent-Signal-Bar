pragma Singleton
import QtQuick
import AgentSignal

// Port of DesignSystem.swift (ASB): one scale of type, spacing, radii and colors shared
// by the settings window, the tray panel, the system menu and the floating light.
// Red, yellow and green are reserved for the light language.
QtObject {
    readonly property bool dark: App.dark
    readonly property string font: App.uiFont
    readonly property color accent: App.accent
    // Text and icons on an accent fill. Windows hands Qt a light accent in dark mode and a dark
    // one in light mode (a grey accent becomes #DFDEDC in dark mode), so a fixed white can vanish.
    readonly property color textOnAccent: 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b > 0.55
        ? Qt.rgba(0, 0, 0, 0.9) : "white"

    // Localisation: binding-safe (reads App.language, so text updates on language change).
    function t(zhHans, english) { return App.language === "zh" ? zhHans : english }

    // Typeface sizes (px == pt at 100 %).
    readonly property int valueSize: 22
    readonly property int titleSize: 15
    readonly property int bodySize: 13
    readonly property int captionSize: 11
    readonly property int badgeSize: 10

    // 4-point spacing scale and radii.
    readonly property int xs: 4
    readonly property int s: 8
    readonly property int m: 12
    readonly property int l: 16
    readonly property int xl: 20
    readonly property int xxl: 24
    readonly property int radiusControl: 6
    readonly property int radiusGroup: 10
    readonly property int radiusPanel: 14

    // Liquid glass → Windows 11 Mica: the settings surfaces turn translucent so the DWM
    // backdrop shows through. Elsewhere (and with glass off) they stay opaque.
    readonly property bool glass: App.supportsBackdrop && App.prefs.glassEnabled === true
    function surface(c, glassAlpha) { return glass ? Qt.rgba(c.r, c.g, c.b, glassAlpha) : c }

    // Surfaces.
    readonly property color windowBg: surface(dark ? "#1e1e1e" : "#f3f3f3", 0)
    readonly property color contentBg: surface(dark ? "#232323" : "#f5f5f5", 0.45)
    readonly property color sidebarBg: surface(dark ? "#2c2c2e" : "#e9e9ec", 0.25)
    readonly property color groupFill: dark ? Qt.rgba(0.172, 0.172, 0.172, 1) : "#ffffff"
    readonly property color groupStroke: dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.07)
    readonly property color track: dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.10)
    readonly property color text: dark ? Qt.rgba(1, 1, 1, 0.88) : Qt.rgba(0, 0, 0, 0.86)
    readonly property color secondary: dark ? Qt.rgba(1, 1, 1, 0.55) : Qt.rgba(0, 0, 0, 0.50)
    readonly property color tertiary: dark ? Qt.rgba(1, 1, 1, 0.30) : Qt.rgba(0, 0, 0, 0.28)
    readonly property color separator: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.09)
    readonly property color panelBg: dark ? Qt.rgba(0.17, 0.17, 0.18, 0.97) : Qt.rgba(0.96, 0.96, 0.97, 0.97)
    readonly property color panelStroke: dark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.12)
    readonly property color insetTile: dark ? Qt.rgba(1, 1, 1, 0.045) : Qt.rgba(0, 0, 0, 0.045)
    readonly property color controlBg: dark ? Qt.rgba(1, 1, 1, 0.10) : "#ffffff"
    readonly property color controlStroke: dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.13)
    readonly property color hoverFill: dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.05)

    // Light language.
    readonly property color lampGreen: Qt.rgba(0.19, 0.82, 0.35, 1)
    readonly property color lampYellow: Qt.rgba(1.0, 0.72, 0.0, 1)
    readonly property color lampRed: Qt.rgba(1.0, 0.23, 0.19, 1)
    readonly property color lampGray: Qt.rgba(0.56, 0.56, 0.58, 1)
    // TrafficSignalView lamp bodies (slightly different from the tone colors).
    function lampBody(name) {
        if (name === "red") return Qt.rgba(0.94, 0.20, 0.18, 1)
        if (name === "yellow") return Qt.rgba(0.97, 0.72, 0.16, 1)
        return Qt.rgba(0.16, 0.78, 0.34, 1)
    }

    // ASBTone: positive, caution, critical, neutral, accent.
    function toneForState(state) {
        if (state === "ready" || state === "active" || state === "completed") return "positive"
        if (state === "needs_review" || state === "stale") return "caution"
        if (state === "permission" || state === "blocked") return "critical"
        return "neutral"
    }
    function toneForRemaining(percent) {
        if (percent === undefined || percent === null) return "neutral"
        if (percent <= 0) return "critical"
        return percent < 20 ? "caution" : "accent"
    }
    function toneLamp(tone) {
        switch (tone) {
        case "positive": return lampGreen
        case "caution": return lampYellow
        case "critical": return lampRed
        case "neutral": return lampGray
        default: return accent
        }
    }
    function toneForeground(tone) {
        switch (tone) {
        case "positive": return dark ? Qt.rgba(0.36, 0.82, 0.48, 1) : Qt.rgba(0.09, 0.42, 0.18, 1)
        case "caution": return dark ? Qt.rgba(1.0, 0.82, 0.37, 1) : Qt.rgba(0.48, 0.32, 0.0, 1)
        case "critical": return dark ? Qt.rgba(1.0, 0.50, 0.46, 1) : Qt.rgba(0.65, 0.11, 0.07, 1)
        case "neutral": return secondary
        default: return accent
        }
    }
    function toneBackground(tone) {
        if (tone === "neutral") return dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.08)
        const base = toneLamp(tone)
        return Qt.rgba(base.r, base.g, base.b, tone === "accent" ? 0.14 : 0.16)
    }

    function stateTitle(state) {
        switch (state) {
        case "ready": return t("空闲", "Idle")
        case "active": return t("工作中", "Working")
        case "completed": return t("已完成", "Done")
        case "needs_review": return t("需要查看", "Needs Review")
        case "permission": return t("等待授权", "Waiting for Permission")
        case "blocked": return t("阻塞/失败", "Blocked")
        case "stale": return t("状态不可信", "Stale")
        default: return t("已暂停", "Paused")
        }
    }
    // AppLocalization.humanAction
    function stateAction(state) {
        switch (state) {
        case "needs_review": return t("有空看一眼", "Review when available")
        case "permission":
        case "blocked": return t("马上处理", "Needs action now")
        case "stale": return t("确认状态", "Confirm status")
        case "paused": return t("监控已暂停", "Monitoring paused")
        default: return t("不用处理", "No action needed")
        }
    }
    // AgentSignal.summary for the display state's representative signal.
    function stateSummary(state) {
        switch (state) {
        case "ready": return t("Agent 空闲。", "Agent is idle.")
        case "active": return t("Agent 正在读写文件、跑工具或测试。", "Agent is reading, editing, running tools or tests.")
        case "completed": return t("任务完成。", "Task finished.")
        case "needs_review": return t("Agent 明确需要你看一眼或继续。", "Agent needs you to look or continue.")
        case "permission": return t("Agent 正在等待用户授权。", "Agent is waiting for your approval.")
        case "blocked": return t("Agent 遇到失败、阻塞或无法继续。", "Agent hit a failure or cannot continue.")
        case "stale": return t("状态文件过期、损坏，或当前状态不可信。", "The state file is stale, damaged or untrusted.")
        default: return t("监控已暂停。", "Monitoring is paused.")
        }
    }
}
