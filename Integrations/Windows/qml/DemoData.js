.pragma library

// Synthetic demo data, matching docs/SCREENSHOTS.md (email demo@agentsignalbar.app).
// The interface shell renders from this until the Windows data layer is ported.

// 30 days of token use (millions); the last entry is "today".
const astra = [0.52, 0.71, 1.05, 0.58, 0.40, 0.49, 0.96, 1.42, 1.30, 1.36, 0.54, 1.12, 0.88, 0.92, 1.08,
               0.47, 1.25, 1.21, 0.62, 1.02, 0.76, 0.68, 0.84, 1.18, 0.95, 1.03, 0.44, 1.20, 0.80, 0.9876]
const gpt56 = [0.18, 0.22, 0.31, 0.20, 0.14, 0.17, 0.33, 0.48, 0.42, 0.45, 0.19, 0.36, 0.30, 0.31, 0.37,
               0.16, 0.41, 0.40, 0.21, 0.34, 0.25, 0.22, 0.28, 0.39, 0.32, 0.35, 0.15, 0.40, 0.27, 0.3292]

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function days(t) {
    const out = []
    const start = new Date(2026, 7, 10) // 10 Aug
    for (let i = 0; i < astra.length; ++i) {
        const d = new Date(start.getTime() + i * 86400000)
        const total = astra[i] + gpt56[i]
        out.push({
            label: t((d.getMonth() + 1) + "月" + d.getDate() + "日", months[d.getMonth()] + " " + d.getDate()),
            total: total,
            models: [
                { name: "GPT-6 Astra", tokens: astra[i], cost: astra[i] * 5.559, color: "#6F52F0" },
                { name: "gpt-5.6", tokens: gpt56[i], cost: gpt56[i] * 5.559, color: "#D56F9B" }
            ]
        })
    }
    return out
}

function tokensText(t, millions) {
    if (t("zh", "en") === "zh") return (millions * 100).toLocaleString("en", { maximumFractionDigits: 2, minimumFractionDigits: 2 }) + "万"
    return millions.toFixed(2) + "M"
}

function account(t) {
    return {
        provider: "Codex",
        email: "demo@agentsignalbar.app",
        plan: "Pro",
        source: t("Demo Account · Codex OAuth", "Demo Account · Codex OAuth"),
        updated: t("更新 16:25", "Updated 16:25"),
        quotas: [
            { title: t("5 小时", "5 hours"), remaining: 76, reset: t("重置 18:25", "Resets 18:25") },
            { title: t("一周", "Weekly"), remaining: 62, reset: t("重置 9月12日 16:25", "Resets Sep 12, 16:25") }
        ],
        resetCredits: t("限额重置额度 · 0 次可用", "Limit resets · 0 available"),
        resetCreditsDetail: t("暂无可用额度", "No credits available"),
        today: { cost: "US$7.32", tokens: t("131.68万 Token", "1.32M tokens") },
        month: { cost: "US$190.99", tokens: t("3,437.79万 Token", "34.38M tokens") },
        topModel: "gpt-6-astra",
        scan: t("扫描完成 100% · 16:25", "Scan complete 100% · 16:25")
    }
}

function sessions(t) {
    return [
        { agent: "Codex", state: "active", pill: t("终端运行中", "Terminal running"), detail: t("收到任务", "Task received"), source: "Codex CLI" }
    ]
}

function events(t) {
    return [
        { title: "Codex CLI", detail: t("任务完成", "Task finished"), time: "16:05", state: "completed" },
        { title: "Codex CLI", detail: t("正在运行工具", "Running a tool"), time: "16:02", state: "active" },
        { title: "Codex Desktop", detail: t("等待授权", "Waiting for permission"), time: "15:48", state: "permission" }
    ]
}

function projects(t) {
    return [
        { name: "agent-signal-bar", sessions: 14, tokens: t("1,821.40万", "18.21M"), cost: "$102.40", share: 0.53 },
        { name: "agentsignalbar.app", sessions: 6, tokens: t("912.06万", "9.12M"), cost: "$51.30", share: 0.27 },
        { name: "scratch", sessions: 9, tokens: t("704.33万", "7.04M"), cost: "$37.29", share: 0.20 }
    ]
}
