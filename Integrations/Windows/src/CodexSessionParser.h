// Port of AgentSignalLightCore/CodexDesktopSessionParser.swift (activity part). Keep the
// branch order in lockstep with the Swift source; tests/tst_codex.cpp replays golden output
// generated from the Swift implementation (tests/golden/codex_parser.swift).
#pragma once

#include <QByteArray>
#include <QString>
#include <optional>

namespace asb::codex {

// One lamp-relevant record from a Codex rollout JSONL line.
struct Activity {
    QString signal;    // canonical AgentSignal raw value: thinking, working, tool_done, done, ...
    QString sessionID; // "<agent prefix>:<thread id>"
    QString agent;     // codex-desktop, codex-cli, codex-vscode, ...
    QString event;     // DesktopTaskStarted, DesktopToolCall:<name>, DesktopTaskComplete, ...
    std::optional<qint64> timestampMs; // Unix milliseconds

    bool operator==(const Activity &) const = default;
};

std::optional<Activity> activity(const QByteArray &line, const QString &defaultSessionID,
                                 const QString &defaultAgent = QStringLiteral("codex-desktop"));

// session_meta lines.
std::optional<QString> agentNameFromSessionMeta(const QByteArray &line);
std::optional<QString> sessionIDFromSessionMeta(const QByteArray &line);
std::optional<QString> forkedFromSessionIDFromSessionMeta(const QByteArray &line);

// ISO 8601 with a time zone, with or without fractional seconds (ISO8601DateFormatter's
// .withInternetDateTime [+ .withFractionalSeconds]).
std::optional<qint64> parseTimestamp(const QString &value);

// The agent's session-ID prefix (sessionPrefix(for:)).
QString sessionPrefix(const QString &agent);

} // namespace asb::codex
