import QtQuick
import AgentSignal

// Owns every window and routes tray / menu requests to them. With --capture it renders
// each surface to PNG (dark and light, Chinese and English) and quits.
QtObject {
    id: root

    property SettingsWindow settings: SettingsWindow {}
    property TrayPanel panel: TrayPanel {}
    property SystemMenu systemMenu: SystemMenu {}
    property UpdateWindow updateWindow: UpdateWindow {}
    property FloatingSignal floating: FloatingSignal {
        visible: App.captureDir.length === 0 && App.prefs.floatingEnabled
    }

    property Connections router: Connections {
        target: App
        function onSettingsRequested(page) { root.settings.open(page) }
        function onUpdateWindowRequested() { root.updateWindow.present(false) }
        function onUpdatePermissionRequested() { root.updateWindow.present(true) }
        // A click on the icon while a popup is open closes it: by the time the click arrives the
        // taskbar took focus and the popup already hid itself, so do not open it again.
        function onPanelRequested() {
            root.systemMenu.hide()
            if (root.panel.visible) root.panel.hide()
            else if (!root.panel.justAutoHidden()) root.panel.present()
        }
        function onSystemMenuRequested() {
            root.panel.hide()
            if (root.systemMenu.visible) root.systemMenu.hide()
            else if (!root.systemMenu.justAutoHidden()) root.systemMenu.present()
        }
    }

    Component.onCompleted: {
        if (App.captureDir.length > 0) captureTimer.start()
        else if (!App.prefs.statusBarEnabled) settings.open("")
    }

    // ---- Capture mode -------------------------------------------------------------
    // Grabs complete asynchronously on the next rendered frame, so every save gets a
    // settle step before the window is hidden or the language/theme changes.
    function grabStep(win, name) { return [() => save(win, name), () => {}] }
    function save(win, name) {
        const ok = win.contentItem.grabToImage(result => {
            if (!result.saveToFile(App.captureDir + "/" + name + ".png")) console.warn("capture: could not save", name)
        })
        if (!ok) console.warn("capture: grab failed for", name, "visible", win.visible, win.width, win.height)
    }
    function settingsStep(page, name) {
        return [() => { settings.open(page) }].concat(grabStep(settings, name))
    }
    function captureSteps() {
        let steps = []
        for (const variant of [{ lang: "zh-Hans", theme: "dark", tag: "zh-CN-dark" },
                               { lang: "en", theme: "dark", tag: "en-dark" },
                               { lang: "zh-Hans", theme: "light", tag: "zh-CN-light" },
                               // A table language: macOS translations, English where it has none.
                               { lang: "ja", theme: "light", tag: "ja-light" }]) {
            steps.push(() => { App.prefs.language = variant.lang; App.prefs.theme = variant.theme; App.prefs.showDebugSettings = true })
            for (const page of ["activity", "usage", "light", "connections", "general", "debug", "about"])
                steps = steps.concat(settingsStep(page, "settings-" + page + "-" + variant.tag))
            steps.push(() => { settings.hide(); panel.present() })
            steps = steps.concat(grabStep(panel, "panel-card-" + variant.tag))
            steps.push(() => { panel.hide(); systemMenu.present() })
            steps = steps.concat(grabStep(systemMenu, "panel-system-menu-" + variant.tag))
            steps.push(() => { systemMenu.hide(); floating.show(); floating.raise(); floating.requestActivate() })
            steps = steps.concat(grabStep(floating, "floating-" + variant.tag))
            steps.push(() => { App.prefs.floatingLayout = "horizontal" })
            steps = steps.concat(grabStep(floating, "floating-horizontal-" + variant.tag))
            steps.push(() => { App.prefs.floatingLayout = "vertical"; floating.hide() })
        }
        // The update window: the permission prompt, a new version with Markdown notes, a download, ready.
        for (const variant of [{ lang: "zh-Hans", theme: "dark", tag: "zh-CN-dark" }, { lang: "en", theme: "light", tag: "en-light" }]) {
            steps.push(() => { App.prefs.language = variant.lang; App.prefs.theme = variant.theme; updateWindow.present(true) })
            steps = steps.concat(grabStep(updateWindow, "update-permission-" + variant.tag))
            for (const stage of ["available", "downloading", "ready"]) {
                steps.push(() => { App.setDemoUpdate(stage); updateWindow.present(false) })
                steps = steps.concat(grabStep(updateWindow, "update-" + stage + "-" + variant.tag))
            }
            steps.push(() => { updateWindow.hide(); App.setDemoUpdate("") })
        }
        // Interaction states: lit red lamp, popover, all three lamps on a done-all-steady frame.
        steps.push(() => { App.prefs.language = "zh-Hans"; App.prefs.theme = "dark"; App.setDemoSignal("permission"); floating.show(); floating.raise() })
        for (let i = 0; i < 4; ++i) steps.push(() => save(floating, "floating-permission-" + App.tick))
        steps.push(() => {})
        steps.push(() => floating.popoverWindow.toggle())
        steps = steps.concat(grabStep(floating.popoverWindow, "floating-popover-zh-CN-dark"))
        steps.push(() => { floating.popoverWindow.hide(); App.setDemoSignal("working") })
        steps.push(() => Qt.quit())
        return steps
    }
    property var pending: []
    property Timer captureTimer: Timer {
        interval: 700
        repeat: true
        onTriggered: {
            if (root.pending.length === 0) root.pending = root.captureSteps()
            const step = root.pending.shift()
            step()
        }
    }
}
