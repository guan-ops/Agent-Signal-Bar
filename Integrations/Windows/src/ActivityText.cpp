#include "ActivityText.h"

#include "ActivityDisplay.h"
#include "SignalModel.h"

#include <QHash>
#include <QPair>
#include <QSet>

namespace asb::text {
namespace {

using Names = QHash<QString, QPair<QString, QString>>; // key -> (zh, en)

QString pick(const QPair<QString, QString> &names, bool zh) { return zh ? names.first : names.second; }

QString normalized(const QString &value) {
    QString n = value.trimmed().toLower();
    n.replace('_', '-');
    n.replace(' ', '-');
    return n;
}

bool isPresenceOnly(const SessionStatus &s) {
    const bool presence = s.sessionID.startsWith("desktop-app:") || s.sessionID.startsWith("platform-presence:")
        || s.lastEvent == "DesktopAppRunning" || s.lastEvent.startsWith("PlatformPresence:");
    const DisplayState state = displayState(s.signal);
    return presence && (state == DisplayState::Ready || state == DisplayState::Paused);
}

} // namespace

QString signalName(const QString &signal, bool zh) {
    static const Names names = {
        {"idle", {"空闲", "Idle"}}, {"thinking", {"思考中", "Thinking"}}, {"working", {"工作中", "Working"}},
        {"tool_done", {"步骤完成", "Step Done"}}, {"subagent_start", {"子 Agent 开始", "Subagent Started"}},
        {"subagent_stop", {"子 Agent 完成", "Subagent Done"}}, {"attention", {"需要查看", "Needs Review"}},
        {"notification", {"通知", "Notification"}}, {"done", {"已完成", "Done"}},
        {"permission", {"请求授权", "Permission Required"}}, {"permission_request", {"等待授权", "Waiting for Permission"}},
        {"blocked", {"阻塞/失败", "Blocked"}}, {"failure", {"失败", "Failed"}}, {"error", {"错误", "Error"}},
        {"exception", {"异常", "Exception"}}, {"max_tokens", {"上下文阻塞", "Context Blocked"}},
        {"stale", {"状态不可信", "Stale"}}, {"session_start", {"会话开始", "Session Started"}},
        {"session_end", {"会话结束", "Session Ended"}}, {"turn_end", {"回合结束", "Turn Ended"}},
        {"off", {"已关闭", "Off"}}, {"pause", {"已暂停", "Paused"}}, {"paused", {"已暂停", "Paused"}}};
    const QString key = normalizedSignal(signal).value_or(QStringLiteral("idle"));
    return pick(names.value(key, {"空闲", "Idle"}), zh);
}

QString friendlyAgentName(const QString &agent, bool zh) {
    if (agent.isEmpty()) return QStringLiteral("Agent");
    const QString key = display::normalizedAgentKey(agent, QString());
    if (key == "codex") return QStringLiteral("Codex");
    // friendlyAgentName's Claude list is shorter than normalizedAgentKey's (no VS Code/Xcode aliases).
    static const QSet<QString> claude = {"claude", "claude-code", "claude-desktop", "claude-cli", "claude-terminal",
                                         "terminal-claude", "claude-ide", "idea-claude", "intellij-claude", "jetbrains-claude"};
    if (claude.contains(normalized(agent))) return QStringLiteral("Claude");
    if (normalized(agent) == "manual") return zh ? QStringLiteral("手动") : QStringLiteral("Manual");
    return agent;
}

QString friendlyEventName(const QString &raw, bool zh) {
    if (raw.startsWith("DesktopToolCall:")) {
        const QString tool = raw.mid(16);
        return (zh ? QStringLiteral("正在执行步骤 ") : QStringLiteral("Running step ")) + tool;
    }
    if (raw.startsWith("PreToolUse:")) return (zh ? "正在执行步骤 " : "Running Step ") + raw.mid(11);
    if (raw.startsWith("PostToolUseFailure:")) return (zh ? "工具失败 " : "Tool Failed ") + raw.mid(19);
    if (raw.startsWith("PostToolUse:")) return (zh ? "步骤完成 " : "Step Done ") + raw.mid(12);
    static const Names names = {
        {"ConfigChange", {"配置变化", "Config Changed"}}, {"CwdChanged", {"目录变化", "Directory Changed"}},
        {"Elicitation", {"请求输入", "Input Requested"}}, {"ElicitationResult", {"输入返回", "Input Returned"}},
        {"FileChanged", {"文件变化", "File Changed"}}, {"InstructionsLoaded", {"指令加载", "Instructions Loaded"}},
        {"SessionStart", {"开始", "Started"}}, {"TaskCreated", {"任务创建", "Task Created"}},
        {"TaskCompleted", {"任务完成", "Task Completed"}}, {"TeammateIdle", {"队友空闲", "Teammate Idle"}},
        {"UserPromptExpansion", {"扩展任务", "Prompt Expanded"}}, {"UserPromptSubmit", {"收到任务", "Prompt Received"}},
        {"PreToolUse", {"正在执行步骤", "Running Step"}}, {"PostToolBatch", {"工具批次完成", "Tool Batch Done"}},
        {"PostToolUse", {"步骤完成", "Step Done"}}, {"PostToolUseFailure", {"工具失败", "Tool Failed"}},
        {"PreCompact", {"整理上下文", "Compacting"}}, {"PostCompact", {"上下文整理完成", "Compacted"}},
        {"SubagentStart", {"子 Agent 开始", "Subagent Started"}}, {"SubagentStop", {"子 Agent 完成", "Subagent Done"}},
        {"PermissionRequest", {"等待授权", "Waiting for Permission"}}, {"PermissionDenied", {"授权被拒绝", "Permission Denied"}},
        {"Notification", {"通知", "Notification"}}, {"Stop", {"完成", "Done"}}, {"StopFailure", {"停止失败", "Stop Failed"}},
        {"WorktreeCreate", {"创建工作区", "Worktree Created"}}, {"WorktreeRemove", {"移除工作区", "Worktree Removed"}},
        {"SessionEnd", {"会话结束", "Session Ended"}}, {"ManualSet", {"手动设置", "Manual Set"}},
        {"DesktopThinking", {"思考中", "Thinking"}}, {"DesktopToolDone", {"步骤完成", "Step Done"}},
        {"DesktopMessage", {"输出中", "Responding"}}, {"DesktopTaskStarted", {"思考中", "Thinking"}},
        {"DesktopActivityHeartbeat", {"活动中", "Active"}}, {"DesktopContextCompacted", {"整理上下文", "Compacting Context"}},
        {"DesktopTaskComplete", {"完成", "Done"}}, {"DesktopTurnAborted", {"已取消", "Canceled"}},
        {"DesktopAppRunning", {"桌面版已打开", "Desktop app open"}}};
    if (names.contains(raw)) return pick(names.value(raw), zh);
    QString fallback = raw;
    fallback.replace('_', ' ');
    fallback.replace('-', ' ');
    return fallback;
}

QString runtimeLabel(const SessionStatus &s, bool zh) {
    const bool presenceOnly = isPresenceOnly(s);
    auto t = [zh](const QString &c, const QString &e) { return zh ? c : e; };
    switch (display::runtimeKind(s.agent, s.sessionID, s.lastEvent)) {
    case display::RuntimeKind::Desktop:
        return presenceOnly ? t("桌面版已开启", "Desktop app open") : t("桌面版运行中", "Desktop running");
    case display::RuntimeKind::Terminal:
        return presenceOnly ? t("终端已检测到", "Terminal detected") : t("终端运行中", "Terminal running");
    case display::RuntimeKind::Ide:
        if (auto detail = display::sourceDetail(s.agent, s.sessionID, s.lastEvent))
            return presenceOnly ? t(*detail + " 已检测到", *detail + " detected") : t(*detail + " 运行中", *detail + " running");
        return presenceOnly ? t("IDE 已检测到", "IDE detected") : t("IDE 运行中", "IDE running");
    case display::RuntimeKind::Local:
        return presenceOnly ? t("本地已检测到", "Local detected") : t("本地运行中", "Local running");
    }
    return {};
}

QString sessionTitle(const SessionStatus &s, bool zh) {
    return friendlyAgentName(s.agent, zh) + " · " + runtimeLabel(s, zh);
}

QString sessionSubtitle(const SessionStatus &s, bool zh) {
    const QString status = signalName(s.signal, zh);
    const QString raw = s.lastEvent.trimmed();
    if (raw.isEmpty()) return status;
    const QString lower = raw.toLower();
    if (lower.startsWith("platformpresence:") || lower == "desktopapprunning") return status;
    const DisplayState state = displayState(s.signal);
    if (raw.startsWith("DesktopToolCall:") && (state == DisplayState::NeedsReview || state == DisplayState::Permission)) {
        const QString tool = raw.mid(16);
        return tool.isEmpty() ? status : status + " · " + tool;
    }
    const QString name = friendlyEventName(raw, zh);
    return name.isEmpty() ? status : name;
}

QString eventTitle(const SignalEvent &e, bool zh) {
    const QString base = friendlyAgentName(e.agent, zh);
    switch (display::runtimeKind(e.agent, e.sessionID, e.event)) {
    case display::RuntimeKind::Desktop: return base + " Desktop";
    case display::RuntimeKind::Terminal: return base + " CLI";
    case display::RuntimeKind::Ide:
        if (auto detail = display::sourceDetail(e.agent, e.sessionID, e.event)) return base + ' ' + *detail;
        return base + " IDE";
    case display::RuntimeKind::Local: return base;
    }
    return base;
}

QString eventSubtitle(const SignalEvent &e, bool zh) {
    const QString name = e.event.trimmed();
    return name.isEmpty() ? signalName(e.signal, zh) : friendlyEventName(name, zh);
}

} // namespace asb::text
