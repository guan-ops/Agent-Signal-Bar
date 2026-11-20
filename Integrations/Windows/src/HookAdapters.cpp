#include "HookAdapters.h"

#include "SignalModel.h"

#include <QJsonArray>
#include <QSet>
#include <cmath>

namespace asb::hooks {
namespace {

// normalizedEventName: lowercase letters and digits only.
QString normalizedName(const QString &value) {
    QString result;
    for (const QChar c : value.trimmed().toLower()) {
        if (c.isLetterOrNumber()) result.append(c);
    }
    return result;
}

// scalarString: strings, booleans and numbers. A JSON 0 or 1 bridges to Bool first in Swift.
std::optional<QString> scalarString(const QJsonValue &value) {
    if (value.isString()) return value.toString();
    if (value.isBool()) return value.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    if (value.isDouble()) {
        const double d = value.toDouble();
        if (d == 1) return QStringLiteral("true");
        if (d == 0) return QStringLiteral("false");
        if (std::floor(d) == d && std::fabs(d) < 1e15) return QString::number(qint64(d));
        return QString::number(d, 'g', 15);
    }
    return std::nullopt;
}

std::optional<QString> firstString(const QJsonObject &payload, const QStringList &keys) {
    for (const QString &key : keys) {
        const auto value = scalarString(payload.value(key));
        if (value && !value->trimmed().isEmpty()) return value;
    }
    for (const QString &key : keys) {
        const QString expected = normalizedName(key);
        for (auto it = payload.constBegin(); it != payload.constEnd(); ++it) {
            if (normalizedName(it.key()) != expected) continue;
            const auto value = scalarString(it.value());
            if (value && !value->trimmed().isEmpty()) return value;
        }
    }
    return std::nullopt;
}

bool shouldSearchNestedContainer(const QString &key) {
    static const QSet<QString> ignored = {"arg", "args", "argument", "arguments", "body", "content", "contents",
        "input", "inputs", "item", "items", "message", "messages", "parameter", "parameters", "param", "params",
        "prompt", "prompts", "text", "texts", "toolinput", "toolinputs", "toolarguments", "toolparameters",
        "userdata", "userinput"};
    static const QSet<QString> metadata = {"context", "conversation", "data", "detail", "details", "event", "hook",
        "metadata", "meta", "payload", "request", "response", "result", "run", "session", "source", "thread",
        "tool", "toolcontext", "transcript", "workspace"};
    const QString n = normalizedName(key);
    return !ignored.contains(n) && metadata.contains(n);
}

std::optional<QString> findNestedString(const QJsonValue &value, const QStringList &keys) {
    if (value.isObject()) {
        const QJsonObject object = value.toObject();
        if (auto direct = firstString(object, keys)) return direct->trimmed();
        for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
            if (!shouldSearchNestedContainer(it.key())) continue;
            if (auto found = findNestedString(it.value(), keys)) return found;
        }
    } else if (value.isArray()) {
        for (const QJsonValue &child : value.toArray()) {
            if (auto found = findNestedString(child, keys)) return found;
        }
    }
    return std::nullopt;
}

bool isFailureWord(const QString &value) {
    return value.contains("error") || value.contains("failed") || value.contains("failure") || value.contains("exception");
}

bool failureValue(const QJsonValue &value) {
    if (value.isBool()) return value.toBool();
    if (value.isDouble()) return value.toDouble() != 0;
    if (value.isString()) {
        const QString n = value.toString().trimmed().toLower();
        static const QSet<QString> benign = {"0", "false", "no", "none", "null", "success", "ok"};
        return !(n.isEmpty() || benign.contains(n));
    }
    return !value.isNull() && !value.isUndefined();
}

bool containsFailureMarker(const QJsonValue &value) {
    static const QSet<QString> failureKeys = {"error", "failure", "exception", "errortype", "errormessage",
                                              "failurereason", "exitstatus", "toolerror"};
    if (value.isObject()) {
        const QJsonObject object = value.toObject();
        for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
            const QString key = normalizedName(it.key());
            if ((failureKeys.contains(key) || isFailureWord(key)) && failureValue(it.value())) return true;
            if (shouldSearchNestedContainer(it.key()) && containsFailureMarker(it.value())) return true;
        }
    } else if (value.isArray()) {
        for (const QJsonValue &child : value.toArray()) {
            if (containsFailureMarker(child)) return true;
        }
    }
    return false;
}

// Tool-step events: a failed step is handed back to the agent, so it never means blocked.
bool isToolStepEvent(const QString &eventName) {
    static const QSet<QString> events = [] {
        QSet<QString> set;
        for (const char *name : {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "ToolStart",
                                 "ToolCall", "ToolDone", "ToolFinished", "ToolCompleted", "ToolFailed", "ToolError"})
            set.insert(normalizedName(QLatin1String(name)));
        return set;
    }();
    return events.contains(normalizedName(eventName));
}

const QStringList kEventKeys = {"hook_event_name", "event_name", "event", "hook", "type", "name"};

} // namespace

namespace claude {
namespace {

const QHash<QString, QString> &eventSignals() {
    static const QHash<QString, QString> map = [] {
        const QList<QPair<const char *, const char *>> pairs = {
            {"ConfigChange", "attention"}, {"CwdChanged", "attention"}, {"Elicitation", "attention"},
            {"ElicitationResult", "working"}, {"FileChanged", "attention"}, {"InstructionsLoaded", "attention"},
            {"SessionStart", "session_start"}, {"TaskCreated", "subagent_start"}, {"TaskCompleted", "subagent_stop"},
            {"TeammateIdle", "idle"}, {"UserPromptExpansion", "thinking"}, {"UserPromptSubmit", "thinking"},
            {"PreToolUse", "working"}, {"PostToolBatch", "tool_done"}, {"PostToolUse", "tool_done"},
            {"PostToolUseFailure", "tool_done"}, {"PreCompact", "working"}, {"PostCompact", "tool_done"},
            {"SubagentStart", "subagent_start"}, {"SubagentStop", "subagent_stop"},
            {"PermissionRequest", "permission_request"}, {"PermissionDenied", "blocked"},
            {"Notification", "notification"}, {"Stop", "done"}, {"StopFailure", "blocked"},
            {"WorktreeCreate", "working"}, {"WorktreeRemove", "attention"}, {"SessionEnd", "session_end"}};
        QHash<QString, QString> m;
        for (const auto &[event, signal] : pairs) m.insert(normalizedName(QLatin1String(event)), QLatin1String(signal));
        return m;
    }();
    return map;
}

QString canonicalName(const QString &value) {
    static const QHash<QString, QString> names = [] {
        QHash<QString, QString> m;
        for (const char *name : {"ConfigChange", "CwdChanged", "Elicitation", "ElicitationResult", "FileChanged",
                                 "InstructionsLoaded", "SessionStart", "TaskCreated", "TaskCompleted", "TeammateIdle",
                                 "UserPromptExpansion", "UserPromptSubmit", "PreToolUse", "PostToolBatch", "PostToolUse",
                                 "PostToolUseFailure", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop",
                                 "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure",
                                 "WorktreeCreate", "WorktreeRemove", "SessionEnd"})
            m.insert(normalizedName(QLatin1String(name)), QLatin1String(name));
        return m;
    }();
    return names.value(normalizedName(value), value.trimmed());
}

std::optional<QString> signalFor(const std::optional<QString> &event) {
    if (!event) return std::nullopt;
    const auto it = eventSignals().constFind(normalizedName(*event));
    if (it == eventSignals().cend()) return std::nullopt;
    return *it;
}

// NSString.lastPathComponent ('/' separated).
QString lastPathComponent(QString path) {
    while (path.size() > 1 && path.endsWith('/')) path.chop(1);
    const qsizetype slash = path.lastIndexOf('/');
    return slash < 0 || path.size() == 1 ? path : path.mid(slash + 1);
}

} // namespace

const QStringList &installedEvents() {
    static const QStringList events = {"ConfigChange", "CwdChanged", "Elicitation", "ElicitationResult", "FileChanged",
        "InstructionsLoaded", "SessionStart", "TaskCreated", "TaskCompleted", "TeammateIdle", "UserPromptExpansion",
        "UserPromptSubmit", "PreToolUse", "PostToolBatch", "PostToolUse", "PostToolUseFailure", "PreCompact",
        "PostCompact", "SubagentStart", "SubagentStop", "PermissionRequest", "PermissionDenied", "Notification", "Stop",
        "StopFailure", "SessionEnd"};
    return events;
}

std::optional<QString> eventName(const QJsonObject &payload) {
    if (auto direct = firstString(payload, kEventKeys)) return direct;
    return findNestedString(payload, kEventKeys);
}

std::optional<QString> displayEventName(const std::optional<QString> &event, const QJsonObject &payload) {
    const std::optional<QString> resolved = event ? event : eventName(payload);
    if (!resolved) return std::nullopt;
    const QString n = normalizedName(*resolved);
    if (n == "pretooluse" || n == "posttooluse" || n == "posttoolusefailure") {
        if (auto tool = firstString(payload, {"tool_name", "tool", "name"}))
            return canonicalName(*resolved) + ':' + tool->trimmed();
    }
    return canonicalName(*resolved);
}

QString chooseSignal(const std::optional<QString> &event, const QJsonObject &payload) {
    if (auto explicitSignal = firstString(payload, {"signal", "signal_name", "lamp_signal"})) {
        if (auto signal = normalizedSignal(*explicitSignal)) return *signal;
    }
    const std::optional<QString> resolvedForTool = event ? event : eventName(payload);
    if (resolvedForTool && isToolStepEvent(*resolvedForTool))
        return signalFor(resolvedForTool).value_or(QStringLiteral("tool_done"));
    if (auto status = firstString(payload, {"status", "state"})) {
        const QString normalized = status->trimmed().toLower();
        if (auto signal = normalizedSignal(normalized)) return *signal;
        if (isFailureWord(normalized)) return QStringLiteral("blocked");
    }
    if (containsFailureMarker(payload)) return QStringLiteral("blocked");

    std::optional<QString> stopReason;
    if (auto reason = firstString(payload, {"stop_reason"})) stopReason = normalizedName(*reason);
    QString resolved = QStringLiteral("Stop");
    if (event) resolved = *event;
    else if (auto fromPayload = eventName(payload)) resolved = *fromPayload;
    if (normalizedName(resolved) == "stop" && stopReason) {
        if (*stopReason == "maxtokens") return QStringLiteral("max_tokens");
        if (isFailureWord(*stopReason)) return QStringLiteral("error");
    }
    return signalFor(resolved).value_or(QStringLiteral("attention"));
}

QString agentName(const Environment &environment) {
    const QString entrypoint = environment.value("CLAUDE_CODE_ENTRYPOINT").trimmed().toLower();
    if (!entrypoint.isEmpty()) {
        if (entrypoint == "claude-desktop") return QStringLiteral("claude-desktop");
        if (entrypoint.contains("vscode")) return QStringLiteral("claude-vscode");
        if (entrypoint.contains("jetbrains") || entrypoint.contains("intellij")) return QStringLiteral("claude-jetbrains");
        return QStringLiteral("claude-code");
    }
    if (environment.value("__CFBundleIdentifier") == "com.anthropic.claudefordesktop") return QStringLiteral("claude-desktop");
    return QStringLiteral("claude-code");
}

QString sessionKey(const QJsonObject &payload, const Environment &environment) {
    const QStringList directKeys = {"session_id", "conversation_id", "thread_id", "chat_id", "claude_session_id"};
    if (auto direct = firstString(payload, directKeys)) return direct->trimmed();
    if (auto nested = findNestedString(payload, directKeys)) return *nested;
    for (const char *key : {"CLAUDE_SESSION_ID", "ANTHROPIC_SESSION_ID"}) {
        const QString value = environment.value(QLatin1String(key)).trimmed();
        if (!value.isEmpty()) return value;
    }
    if (auto transcript = firstString(payload, {"transcript_path"})) {
        const QString trimmed = transcript->trimmed();
        if (!trimmed.isEmpty()) return "transcript:" + lastPathComponent(trimmed);
    }
    if (auto cwd = firstString(payload, {"cwd", "workspace", "workspace_dir", "project_dir"})) return "cwd:" + cwd->trimmed();
    return QStringLiteral("claude-global");
}

} // namespace claude
} // namespace asb::hooks
