#include "CodexSessionParser.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>
#include <QTimeZone>

namespace asb::codex {
namespace {

std::optional<QJsonObject> parseObject(const QByteArray &line) {
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(line, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
    return document.object();
}

// `value as? String`, trimmed and non-empty.
std::optional<QString> trimmedString(const QJsonValue &value) {
    if (!value.isString()) return std::nullopt;
    const QString trimmed = value.toString().trimmed();
    if (trimmed.isEmpty()) return std::nullopt;
    return trimmed;
}

std::optional<QString> stringValue(const QJsonObject &payload, const QStringList &keys) {
    for (const QString &key : keys) {
        if (auto value = trimmedString(payload.value(key))) return value;
    }
    return std::nullopt;
}

bool containsAny(const QString &value, const QStringList &tokens) {
    for (const QString &token : tokens) {
        if (value.contains(token)) return true;
    }
    return false;
}

std::optional<QString> agentName(const QJsonObject &payload) {
    const QString source =
        stringValue(payload, {"source", "client", "app", "application", "entrypoint", "runner"}).value_or(QString()).toLower();
    const QString originator = stringValue(payload, {"originator"}).value_or(QString()).toLower();
    QStringList parts;
    if (!source.isEmpty()) parts << source;
    if (!originator.isEmpty()) parts << originator;
    const QString combined = parts.join(' ');

    if (containsAny(source, {"exec", "cli", "terminal", "shell", "tui"})) return QStringLiteral("codex-cli");
    if (containsAny(originator, {"xcode"})) return QStringLiteral("codex-xcode");
    if (containsAny(originator, {"idea", "intellij"})) return QStringLiteral("codex-idea");
    if (containsAny(originator, {"jetbrains"})) return QStringLiteral("codex-jetbrains");
    if (containsAny(originator, {"codex desktop", "codex_work_desktop", "codex_desktop"})) return QStringLiteral("codex-desktop");
    if (containsAny(combined, {"idea", "intellij"})) return QStringLiteral("codex-idea");
    if (containsAny(combined, {"jetbrains"})) return QStringLiteral("codex-jetbrains");
    if (containsAny(combined, {"visual studio code", "vscode", "vs-code"})) return QStringLiteral("codex-vscode");
    if (containsAny(combined, {"xcode"})) return QStringLiteral("codex-xcode");
    if (containsAny(combined, {"ide"})) return QStringLiteral("codex-ide");
    if (containsAny(combined, {"desktop", "app"})) return QStringLiteral("codex-desktop");
    return std::nullopt;
}

std::optional<QString> payloadSessionID(const QJsonObject &payload, const QString &agent) {
    for (const char *key : {"threadId", "thread_id", "conversationId", "conversation_id"}) {
        if (auto value = trimmedString(payload.value(QLatin1String(key)))) return sessionPrefix(agent) + ':' + *value;
    }
    return std::nullopt;
}

QString toolName(const QJsonObject &payload) {
    return trimmedString(payload.value("name")).value_or(QStringLiteral("tool"));
}

bool requiresEscalatedApproval(const QJsonObject &payload) {
    const QJsonValue arguments = payload.value("arguments");
    if (arguments.isObject() && arguments.toObject().value("sandbox_permissions") == QJsonValue("require_escalated"))
        return true;
    if (!arguments.isString()) return false;
    const QString text = arguments.toString();
    if (!text.contains("sandbox_permissions") || !text.contains("require_escalated")) return false;
    if (auto object = parseObject(text.toUtf8()))
        return object->value("sandbox_permissions") == QJsonValue("require_escalated");
    return text.contains(R"("sandbox_permissions":"require_escalated")")
        || text.contains(R"("sandbox_permissions": "require_escalated")");
}

QString toolCallSignal(const QJsonObject &payload) {
    if (requiresEscalatedApproval(payload)) return QStringLiteral("permission_request");
    if (toolName(payload).toLower() == "request_user_input") return QStringLiteral("attention");
    return QStringLiteral("working");
}

Activity make(const QString &signal, const QString &sessionID, const QString &agent, const QString &event,
              std::optional<qint64> timestamp) {
    return Activity{signal, sessionID, agent, event, timestamp};
}

std::optional<Activity> fromEventMessage(const QJsonObject &payload, const QString &sessionID, const QString &agent,
                                         std::optional<qint64> ts) {
    const QString type = payload.value("type").toString();
    // token_count records are written during and after a turn; they are metadata only.
    if (type == "task_started" || type == "user_message")
        return make("thinking", sessionID, agent, "DesktopTaskStarted", ts);
    if (type == "task_complete") return make("done", sessionID, agent, "DesktopTaskComplete", ts);
    if (type == "turn_aborted") return make("done", sessionID, agent, "DesktopTurnAborted", ts);
    if (type == "agent_message") {
        if (payload.value("phase") == QJsonValue("final_answer"))
            return make("done", sessionID, agent, "DesktopTaskComplete", ts);
        return make("working", sessionID, agent, "DesktopMessage", ts);
    }
    return std::nullopt;
}

std::optional<Activity> fromResponseItem(const QJsonObject &payload, const QString &sessionID, const QString &agent,
                                         std::optional<qint64> ts) {
    const QString type = payload.value("type").toString();
    if (type == "reasoning") return make("thinking", sessionID, agent, "DesktopThinking", ts);
    if (type == "function_call" || type == "custom_tool_call")
        return make(toolCallSignal(payload), sessionID, agent, "DesktopToolCall:" + toolName(payload), ts);
    if (type == "function_call_output") return make("tool_done", sessionID, agent, "DesktopToolDone", ts);
    if (type == "message") {
        if (payload.value("role") == QJsonValue("user")) return std::nullopt;
        if (payload.value("phase") == QJsonValue("final_answer"))
            return make("done", sessionID, agent, "DesktopTaskComplete", ts);
        return make("working", sessionID, agent, "DesktopMessage", ts);
    }
    return std::nullopt;
}

std::optional<QJsonObject> sessionMetaObject(const QByteArray &line) {
    auto object = parseObject(line);
    if (!object || object->value("type") != QJsonValue("session_meta")) return std::nullopt;
    return object;
}

} // namespace

std::optional<qint64> parseTimestamp(const QString &value) {
    // Full date, time and an explicit zone; fractional seconds optional.
    static const QRegularExpression pattern(
        QStringLiteral(R"(^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$)"));
    if (!pattern.match(value).hasMatch()) return std::nullopt;
    const QDateTime parsed = QDateTime::fromString(value, Qt::ISODateWithMs);
    if (!parsed.isValid()) return std::nullopt;
    return parsed.toMSecsSinceEpoch();
}

QString sessionPrefix(const QString &agent) {
    const QString a = agent.toLower();
    if (a == "codex-cli") return QStringLiteral("codex-cli");
    if (a == "codex-idea" || a == "codex-intellij") return QStringLiteral("codex-idea");
    if (a == "codex-jetbrains") return QStringLiteral("codex-jetbrains");
    if (a == "codex-vscode") return QStringLiteral("codex-vscode");
    if (a == "codex-xcode") return QStringLiteral("codex-xcode");
    if (a == "codex-ide") return QStringLiteral("codex-ide");
    return QStringLiteral("codex-desktop");
}

std::optional<Activity> activity(const QByteArray &line, const QString &defaultSessionID, const QString &defaultAgent) {
    const auto object = parseObject(line);
    if (!object) return std::nullopt;

    const QJsonValue timestampValue = object->value("timestamp");
    const std::optional<qint64> ts =
        timestampValue.isString() ? parseTimestamp(timestampValue.toString()) : std::nullopt;
    const QString topLevelType = object->value("type").toString();
    const QJsonObject payload = object->value("payload").toObject();
    const QString agent = agentName(payload).value_or(defaultAgent);
    const QString sessionID = payloadSessionID(payload, agent).value_or(defaultSessionID);

    if (topLevelType == "compacted") return make("thinking", sessionID, agent, "DesktopContextCompacted", ts);
    if (topLevelType == "event_msg") return fromEventMessage(payload, sessionID, agent, ts);
    if (topLevelType == "response_item") return fromResponseItem(payload, sessionID, agent, ts);
    return std::nullopt;
}

std::optional<QString> agentNameFromSessionMeta(const QByteArray &line) {
    const auto object = sessionMetaObject(line);
    if (!object || !object->value("payload").isObject()) return std::nullopt;
    return agentName(object->value("payload").toObject());
}

std::optional<QString> sessionIDFromSessionMeta(const QByteArray &line) {
    const auto object = sessionMetaObject(line);
    if (!object) return std::nullopt;
    const QJsonObject payload = object->value("payload").toObject();
    // Subagent metadata can use session_id for its parent while id identifies this session.
    for (const QJsonValue &value : {payload.value("id"), payload.value("session_id"), payload.value("sessionId"),
                                    object->value("id"), object->value("session_id"), object->value("sessionId")}) {
        if (auto trimmed = trimmedString(value)) return trimmed;
    }
    return std::nullopt;
}

std::optional<QString> forkedFromSessionIDFromSessionMeta(const QByteArray &line) {
    const auto object = sessionMetaObject(line);
    if (!object || !object->value("payload").isObject()) return std::nullopt;
    return stringValue(object->value("payload").toObject(),
                       {"forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"});
}

} // namespace asb::codex
