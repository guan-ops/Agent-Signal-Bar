// Localised names for sessions and events (Simplified Chinese and English). Port of
// AppLanguage.swift (displayName(for: AgentSignal), friendlyAgentName, friendlyEventName)
// and the MenuBarStatusModel extension in ActivityPresentation.swift.
#pragma once

#include "SignalStore.h"

namespace asb::text {

QString signalName(const QString &signal, bool zh);
QString friendlyAgentName(const QString &agent, bool zh);
QString friendlyEventName(const QString &event, bool zh);

// "Codex · 终端运行中" (activitySessionTitle) and its parts.
QString runtimeLabel(const SessionStatus &session, bool zh);
QString sessionTitle(const SessionStatus &session, bool zh);
// "正在执行步骤 shell" / "等待授权 · shell" (activitySessionStatusSubtitle).
QString sessionSubtitle(const SessionStatus &session, bool zh);
// "Codex CLI" (activityEventTitle) and "完成" (activityEventSubtitle).
QString eventTitle(const SignalEvent &event, bool zh);
QString eventSubtitle(const SignalEvent &event, bool zh);

} // namespace asb::text
