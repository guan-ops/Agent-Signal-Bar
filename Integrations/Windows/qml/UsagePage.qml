import QtQuick
import QtQuick.Layouts
import AgentSignal
import "DemoData.js" as Demo

// 用量 / Usage: account, quota windows, reset credits, token usage, projects.
SettingsPage {
    id: page
    readonly property var account: Demo.account(Theme.t)
    readonly property bool claude: App.prefs.usagePlatform === "claude"
    // Account quota from this PC's logins; null in demo and capture runs (the demo cards show).
    readonly property var codexLive: App.liveData && App.quota.codex !== undefined ? App.quota.codex : null
    readonly property var claudeLive: App.liveData && App.quota.claude !== undefined ? App.quota.claude : null
    // Local token usage: the scan when live, else the demo set (Codex only).
    readonly property var usage: App.liveData ? (App.usage[page.claude ? "claude" : "codex"] || null)
                                              : (page.claude ? null : Demo.usage(Theme.t))

    RowLayout {
        Layout.fillWidth: true
        AsbText {
            text: Theme.t("用量", "Usage")
            font.pixelSize: Theme.titleSize
            font.weight: Font.DemiBold
            Layout.fillWidth: true
        }
        StatusPill {
            visible: App.liveData && !page.claude && page.codexLive === null
            text: Theme.t("账号与额度为演示数据", "Account & quota: demo data")
            tone: "caution"
        }
        Dropdown {
            key: "usagePlatform"
            icon: page.claude ? "sparkles" : "terminal"
            pickerWidth: 124
            options: [{ value: "codex", label: "Codex" }, { value: "claude", label: "Claude" }]
        }
    }

    ClaudeUsageCard { visible: page.claude && page.claudeLive === null }

    // Live Codex account (DebugWindowView's account card): the active login, saved accounts, adding
    // one through `codex login`, and the data source details.
    AsbSection {
        visible: !page.claude && page.codexLive !== null
        title: Theme.t("账户", "Account")
        headerAccessory: AsbButton {
            icon: "refresh"
            implicitWidth: 28
            enabled: page.codexLive !== null && !page.codexLive.fetching
            onClicked: App.refreshQuota("codex")
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                width: 30
                height: 30
                radius: 15
                color: Theme.accent
                Icon { anchors.centerIn: parent; name: "person"; size: 18; color: Theme.textOnAccent }
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                AsbText {
                    text: page.codexLive && page.codexLive.signedIn
                        ? (page.codexLive.email || Theme.t("已登录 Codex", "Signed in to Codex"))
                        : Theme.t("未登录 Codex", "Not signed in to Codex")
                    strong: true
                    Layout.fillWidth: true
                }
                AsbText {
                    visible: text.length > 0
                    text: page.codexLive ? page.codexLive.plan : ""
                    caption: true
                    secondary: true
                }
            }
        }
        Flow {
            Layout.fillWidth: true
            spacing: Theme.s
            AsbButton {
                icon: "personAdd"
                text: page.codexLive && page.codexLive.adding ? Theme.t("取消登录", "Cancel Sign-in") : Theme.t("添加账号", "Add Account")
                onClicked: page.codexLive.adding ? App.cancelAddCodexAccount() : App.addCodexAccount()
            }
            AsbButton {
                visible: page.codexLive !== null && page.codexLive.needsSave
                text: Theme.t("保存当前账号", "Save Current")
                onClicked: App.saveCodexAccount()
            }
            Dropdown {
                visible: page.codexLive !== null && page.codexLive.accounts.length > 1
                pickerWidth: 180
                value: page.codexLive ? page.codexLive.activeId : ""
                options: page.codexLive ? page.codexLive.accounts.map(a => ({ value: a.id, label: a.title })) : []
                onActivated: v => { if (v !== page.codexLive.activeId) App.switchCodexAccount(v) }
            }
            AsbButton {
                id: removeAccount
                property bool armed: false
                visible: page.codexLive !== null && page.codexLive.activeId.length > 0
                text: armed ? Theme.t("确认移除？", "Confirm Remove?") : Theme.t("移除账号", "Remove Account")
                onClicked: {
                    if (!armed) {
                        armed = true
                        disarm.restart()
                        return
                    }
                    armed = false
                    App.removeCodexAccount(page.codexLive.activeId)
                }
                Timer { id: disarm; interval: 4000; onTriggered: removeAccount.armed = false }
            }
        }
        AsbText {
            visible: text.length > 0
            text: page.codexLive ? page.codexLive.message : ""
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        AsbRow {
            title: Theme.t("数据来源", "Data source")
            subtitle: Theme.t("自动：有 Cookie 时先用 Cookie，再用 Codex 登录；OAuth API：只用 Codex 登录。",
                              "Automatic tries a pasted cookie, then the Codex sign-in; OAuth API uses the sign-in only.")
            Segmented {
                key: "codexUsageDataSource"
                segmentWidth: 76
                options: [{ value: "automatic", label: Theme.t("自动", "Automatic") }, { value: "oauth-api", label: "OAuth API" }]
            }
        }
        AsbRow {
            title: "OpenAI Cookie"
            subtitle: Theme.t("可选：粘贴 chatgpt.com 的 Cookie 请求头，只在邮箱与 Codex 登录一致时用于 chatgpt.com 的用量接口，加密保存在本机。",
                              "Optional: paste the chatgpt.com Cookie header. Used only for chatgpt.com's usage endpoint when its email matches the Codex sign-in; stored encrypted on this PC.")
            Segmented {
                key: "codexOpenAICookieMode"
                segmentWidth: 60
                options: [{ value: "off", label: Theme.t("关闭", "Off") }, { value: "manual", label: Theme.t("手动", "Manual") }]
            }
        }
        RowLayout {
            visible: App.prefs.codexOpenAICookieMode === "manual"
            Layout.fillWidth: true
            spacing: Theme.s
            SecretField {
                id: cookieField
                Layout.fillWidth: true
                placeholderText: page.codexLive && page.codexLive.hasCookie
                    ? Theme.t("已保存；粘贴新的 Cookie 可替换", "Saved; paste a new cookie to replace it")
                    : Theme.t("粘贴 Cookie 请求头或 curl 命令", "Paste the Cookie header or a curl command")
            }
            AsbButton {
                text: Theme.t("保存", "Save")
                enabled: cookieField.text.length > 0
                onClicked: {
                    cookieError.visible = !App.setCodexCookie(cookieField.text)
                    cookieField.clear()
                }
            }
            AsbButton {
                visible: page.codexLive !== null && page.codexLive.hasCookie
                text: Theme.t("清除", "Clear")
                onClicked: App.setCodexCookie("")
            }
        }
        AsbText {
            id: cookieError
            visible: false
            text: Theme.t("没有找到可用的 Cookie。", "No usable cookie found.")
            caption: true
            color: Theme.toneForeground("caution")
        }
    }

    // Live Codex quota windows (the Session card).
    AsbSection {
        visible: !page.claude && page.codexLive !== null
        title: Theme.t("会话", "Session")
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                AsbText { text: page.codexLive ? page.codexLive.limitTitle : ""; strong: true; Layout.fillWidth: true }
                AsbText { text: page.codexLive ? page.codexLive.source : ""; caption: true; secondary: true }
                AsbText {
                    visible: page.codexLive !== null && page.codexLive.limitId.length > 0
                    text: page.codexLive ? "ID · " + page.codexLive.limitId : ""
                    caption: true
                    color: Theme.tertiary
                }
            }
            AsbText {
                text: page.codexLive ? (page.codexLive.fetching ? Theme.t("正在读取…", "Reading…") : page.codexLive.updated) : ""
                caption: true
                color: Theme.tertiary
                Layout.alignment: Qt.AlignTop
            }
        }
        AsbText {
            visible: text.length > 0
            text: page.codexLive ? page.codexLive.status : ""
            caption: true
            color: Theme.toneForeground("caution")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        QuotaTiles { windows: page.codexLive ? page.codexLive.windows : [] }
        AsbText {
            visible: text.length > 0
            text: page.codexLive ? page.codexLive.credits : ""
            caption: true
            secondary: true
        }
    }

    AsbSection {
        visible: !page.claude && page.codexLive !== null && page.codexLive.resetCredits.title !== undefined
        title: Theme.t("限额重置额度", "Limit Reset Credits")
        RowLayout {
            Layout.fillWidth: true
            AsbText { text: page.codexLive ? (page.codexLive.resetCredits.title || "") : ""; strong: true; Layout.fillWidth: true }
            Icon { name: "clock"; size: 12; color: Theme.secondary }
            AsbText { text: page.codexLive ? (page.codexLive.resetCredits.detail || "") : ""; caption: true; secondary: true }
        }
    }

    // Live Claude quota (ClaudeUsageSettingsView): consent first, then OAuth or a claude.ai session.
    AsbSection {
        visible: page.claude && page.claudeLive !== null
        title: Theme.t("Claude 额度", "Claude Quota")
        headerAccessory: AsbButton {
            icon: "refresh"
            implicitWidth: 28
            enabled: page.claudeLive !== null && !page.claudeLive.fetching
            onClicked: App.refreshQuota("claude")
        }
        ColumnLayout {
            visible: page.claudeLive !== null && !page.claudeLive.consent && App.prefs.claudeProviderSource !== "web"
            Layout.fillWidth: true
            spacing: 6
            AsbText {
                text: Theme.t("查询额度需要读取 Claude Code 的登录凭据（.credentials.json，只读，不会刷新或改写）。令牌只发送给 api.anthropic.com。",
                              "Reading the quota needs the Claude Code sign-in (.credentials.json, read-only, never refreshed or rewritten). The token is sent only to api.anthropic.com.")
                caption: true
                secondary: true
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            AsbButton {
                prominent: true
                text: Theme.t("允许读取 Claude Code 凭据", "Allow Reading Claude Code Credentials")
                onClicked: App.prefs.claudeCredentialConsent = true
            }
        }
        AsbRow {
            title: Theme.t("数据来源", "Data source")
            Segmented {
                key: "claudeProviderSource"
                segmentWidth: 70
                options: [{ value: "oauth", label: "OAuth" }, { value: "web", label: "claude.ai" },
                          { value: "automatic", label: Theme.t("自动", "Automatic") }]
            }
        }
        RowLayout {
            visible: App.prefs.claudeProviderSource !== "oauth"
            Layout.fillWidth: true
            spacing: Theme.s
            SecretField {
                id: sessionField
                Layout.fillWidth: true
                placeholderText: page.claudeLive && page.claudeLive.hasSession
                    ? Theme.t("已保存；粘贴新的 sessionKey 可替换", "Saved; paste a new sessionKey to replace it")
                    : Theme.t("粘贴 claude.ai 的 sessionKey Cookie", "Paste the claude.ai sessionKey cookie")
            }
            AsbButton {
                text: Theme.t("保存", "Save")
                enabled: sessionField.text.length > 0
                onClicked: {
                    sessionError.visible = !App.setClaudeSession(sessionField.text)
                    sessionField.clear()
                }
            }
            AsbButton {
                visible: page.claudeLive !== null && page.claudeLive.hasSession
                text: Theme.t("清除", "Clear")
                onClicked: App.setClaudeSession("")
            }
        }
        AsbText {
            id: sessionError
            visible: false
            text: Theme.t("没有找到有效的 sessionKey。", "No valid sessionKey found.")
            caption: true
            color: Theme.toneForeground("caution")
        }
        AsbRow {
            visible: page.claudeLive !== null && page.claudeLive.organizations.length > 0
            title: Theme.t("组织", "Organization")
            Dropdown {
                key: "claudeWebOrganization"
                pickerWidth: 180
                options: page.claudeLive ? page.claudeLive.organizations : []
            }
        }
        AsbText {
            visible: text.length > 0
            text: page.claudeLive ? page.claudeLive.status : ""
            caption: true
            color: Theme.toneForeground("caution")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            visible: page.claudeLive !== null && page.claudeLive.ready
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                AsbText {
                    text: page.claudeLive ? [page.claudeLive.email, page.claudeLive.plan].filter(s => s && s.length > 0).join(" · ") : ""
                    strong: true
                    Layout.fillWidth: true
                }
                AsbText {
                    text: page.claudeLive ? [page.claudeLive.organization, page.claudeLive.source].filter(s => s && s.length > 0).join(" · ") : ""
                    caption: true
                    secondary: true
                }
            }
            AsbText {
                text: page.claudeLive ? (page.claudeLive.fetching ? Theme.t("正在读取…", "Reading…") : page.claudeLive.updated) : ""
                caption: true
                color: Theme.tertiary
                Layout.alignment: Qt.AlignTop
            }
        }
        QuotaTiles { windows: page.claudeLive ? page.claudeLive.windows : [] }
        Repeater {
            model: page.claudeLive ? page.claudeLive.balances : []
            AsbText {
                required property var modelData
                text: modelData
                caption: true
                secondary: true
            }
        }
        AsbButton {
            visible: page.claudeLive !== null && page.claudeLive.consent
            text: Theme.t("撤销读取授权", "Revoke Credential Access")
            onClicked: App.prefs.claudeCredentialConsent = false
        }
    }

    // Quota windows as tiles: "5 小时 · 剩余 76%" and the reset time.
    component QuotaTiles: Flow {
        property var windows: []
        visible: windows.length > 0
        Layout.fillWidth: true
        spacing: Theme.s
        Repeater {
            model: parent.windows
            Rectangle {
                required property var modelData
                width: (parent.width - Theme.s) / 2
                implicitHeight: tileColumn.implicitHeight + 16
                radius: Theme.radiusControl
                color: Theme.insetTile
                ColumnLayout {
                    id: tileColumn
                    x: 9
                    y: 8
                    width: parent.width - 18
                    spacing: 2
                    AsbText {
                        text: modelData.title + " · " + modelData.valueText
                        strong: true
                        color: Theme.toneForeground(Theme.toneForRemaining(modelData.remaining))
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    AsbText { text: modelData.reset; caption: true; secondary: true; Layout.fillWidth: true }
                }
            }
        }
    }

    // Account.
    AsbSection {
        visible: !page.claude && page.codexLive === null
        title: Theme.t("账户", "Account")
        headerAccessory: AsbButton { icon: "refresh"; implicitWidth: 28 }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
                width: 30
                height: 30
                radius: 15
                color: Theme.accent
                Icon { anchors.centerIn: parent; name: "person"; size: 18; color: Theme.textOnAccent }
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                RowLayout {
                    AsbText { text: page.account.email; strong: true }
                    StatusPill { text: Theme.t("默认", "Default"); tone: "neutral" }
                }
                AsbText { text: page.account.plan; caption: true; secondary: true }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s
            AsbButton { icon: "personAdd"; text: Theme.t("添加账号", "Add Account") }
            Dropdown {
                pickerWidth: 150
                value: "demo"
                options: [{ value: "demo", label: Theme.t("切换", "Switch") }]
            }
            AsbButton { icon: "ellipsis"; implicitWidth: 32 }
            Item { Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        RowLayout {
            Layout.fillWidth: true
            AsbText { text: Theme.t("详情", "Details"); strong: true; Layout.fillWidth: true }
            Icon { name: "chevronDown"; size: 13; color: Theme.secondary }
        }
    }

    // Session quota windows.
    AsbSection {
        visible: !page.claude && page.codexLive === null
        title: Theme.t("会话", "Session")
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                AsbText { text: "Codex"; strong: true; Layout.fillWidth: true }
                AsbText { text: page.account.source; caption: true; secondary: true }
                AsbText { text: "ID · codex"; caption: true; color: Theme.tertiary }
            }
            AsbText { text: page.account.updated; caption: true; color: Theme.tertiary; Layout.alignment: Qt.AlignTop }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s
            Repeater {
                model: page.account.quotas
                Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: quotaColumn.implicitHeight + 16
                    radius: Theme.radiusControl
                    color: Theme.insetTile
                    ColumnLayout {
                        id: quotaColumn
                        x: 9
                        y: 8
                        width: parent.width - 18
                        spacing: 2
                        AsbText {
                            text: modelData.title + Theme.t(" · 剩余 ", " · ") + modelData.remaining + "%" + Theme.t("", " left")
                            strong: true
                        }
                        AsbText { text: modelData.reset; caption: true; secondary: true; Layout.fillWidth: true }
                    }
                }
            }
        }
    }

    AsbSection {
        visible: !page.claude && page.codexLive === null
        title: Theme.t("限额重置额度", "Limit Reset Credits")
        RowLayout {
            Layout.fillWidth: true
            AsbText { text: Theme.t("0 次可用", "0 available"); strong: true; Layout.fillWidth: true }
            Icon { name: "clock"; size: 12; color: Theme.secondary }
            AsbText { text: page.account.resetCreditsDetail; caption: true; secondary: true }
        }
    }

    // Token usage (Codex: CodexUsageDetailsView; Claude: ClaudeUsageSettingsView.historyCard).
    AsbSection {
        visible: page.usage !== null
        title: page.claude ? Theme.t("本机 Token 使用", "Local Token Usage") : Theme.t("Token 使用", "Token Usage")
        headerAccessory: AsbButton {
            visible: App.liveData
            icon: "refresh"
            implicitWidth: 28
            enabled: page.usage !== null && !page.usage.scanning
            onClicked: App.refreshUsage()
        }
        AsbText {
            text: page.claude
                ? Theme.t("汇总本机 Claude Code 会话日志，包含缓存 Token；切换账号不影响统计范围。费用为估算，并非订阅账单。",
                          "Local Claude Code session logs including cached tokens, across accounts. Costs are estimates, not subscription charges.")
                : Theme.t("本机 Codex 会话汇总，不归属于当前所选账号。", "Local Codex sessions, not attributed to the selected account.")
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            spacing: 5
            Icon { name: page.usage && page.usage.ready && !page.usage.scanning ? "check" : "refresh"; size: 12; color: Theme.secondary }
            AsbText { text: page.usage ? page.usage.scan : ""; caption: true; secondary: true }
        }
        AsbText {
            visible: text.length > 0
            text: page.usage ? (page.usage.status || "") : ""
            caption: true
            color: Theme.toneForeground("caution")
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: tokenColumn.implicitHeight + 20
            radius: Theme.radiusControl
            color: Theme.insetTile
            ColumnLayout {
                id: tokenColumn
                x: 10
                y: 10
                width: parent.width - 20
                spacing: 10
                GridLayout {
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 8
                    Layout.fillWidth: true
                    AsbStat { label: Theme.t("今日", "Today"); value: page.usage ? page.usage.today.costText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天费用", "30-day cost"); value: page.usage ? page.usage.month.costText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("今日 token 用量", "Today's tokens"); value: page.usage ? page.usage.today.tokensText : "—"; valueSize: Theme.bodySize }
                    AsbStat { label: Theme.t("近 30 天 token 用量", "30-day tokens"); value: page.usage ? page.usage.month.tokensText : "—"; valueSize: Theme.bodySize }
                }
                TokenChart {
                    id: chart
                    stacked: true
                    days: page.usage ? page.usage.days : []
                    chartHeight: 56
                }
                AsbText {
                    readonly property var d: chart.shown
                    text: d ? d.label + "：" + d.costText + " · " + d.tokensText : ""
                    strong: true
                }
                Repeater {
                    model: chart.shown ? chart.shown.models : []
                    RowLayout {
                        required property var modelData
                        spacing: 8
                        Rectangle { width: 3; Layout.fillHeight: true; radius: 1.5; color: modelData.color }
                        ColumnLayout {
                            spacing: 1
                            AsbText { text: modelData.name; caption: true; strong: true }
                            AsbText {
                                text: modelData.costText + " · " + modelData.tokensText + " · " + modelData.share + "%"
                                caption: true
                                secondary: true
                            }
                        }
                    }
                }
            }
        }
        AsbText {
            visible: text.length > 0
            text: page.usage ? (page.usage.empty || "") : ""
            caption: true
            secondary: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        AsbText {
            visible: text.length > 0
            text: App.liveData ? (App.usage.rateNote || "") : ""
            caption: true
            color: Theme.tertiary
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }

    // Projects and sessions (CodexUsageDetails.projects / buildClaudeUsageDetails).
    AsbSection {
        visible: page.usage !== null && page.usage.projects.length > 0
        title: Theme.t("项目与会话 · 近 30 天", "Projects & Sessions · 30 days")
        footer: page.claude
            ? Theme.t("本机 Claude Code 会话日志，按项目路径汇总。", "Local Claude Code session logs by project path.")
            : Theme.t("本机 Codex 会话日志，按项目路径汇总；不归属于当前所选账号。", "Local Codex session logs by project path; not attributed to the selected account.")
        Repeater {
            model: page.usage ? page.usage.projects : []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    AsbText { text: modelData.name; strong: true; Layout.fillWidth: true }
                    AsbText { text: modelData.cost; strong: true }
                }
                AsbText {
                    text: modelData.sessions + Theme.t(" 个会话 · ", " sessions · ") + modelData.tokens + Theme.t(" token", " tokens")
                    caption: true
                    secondary: true
                }
                AsbMeter { fraction: modelData.share; barHeight: 4 }
            }
        }
    }
}
