// Port of ClaudeHookAdapter from AgentSignalLightCore/HookAdapters.swift: turns a Claude
// Code hook payload (stdin JSON) into a signal, a session key, an agent and the event label
// that is stored. Only those strings are kept; prompts and tool input never leave the
// payload. tests/tst_codex.cpp replays golden output generated from the Swift adapter.
#pragma once

#include <QHash>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <optional>

namespace asb::hooks {

using Environment = QHash<QString, QString>;

namespace claude {

// Claude Code's hook events (NativeHookInstaller.claudeEvents).
const QStringList &installedEvents();

std::optional<QString> eventName(const QJsonObject &payload);
// "PreToolUse:Bash", "Stop", ... (canonical spelling, tool name for tool events).
std::optional<QString> displayEventName(const std::optional<QString> &eventName, const QJsonObject &payload);
QString chooseSignal(const std::optional<QString> &eventName, const QJsonObject &payload);
QString agentName(const Environment &environment);
QString sessionKey(const QJsonObject &payload, const Environment &environment);

} // namespace claude
} // namespace asb::hooks
