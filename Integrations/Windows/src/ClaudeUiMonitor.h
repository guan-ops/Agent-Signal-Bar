// Claude desktop reply state (ClaudeDesktopUIActivityMonitor.swift), through UI Automation instead
// of macOS Accessibility. Optional and off by default: a read-only fallback for cloud sessions
// that emit no local hooks.
//
// Every poll walks Claude desktop's UI Automation tree (at most 1500 elements, 24 levels, 1 s) and
// reports "working" only when an enabled button inside the claude.ai page is labelled exactly like
// the stop-response button (停止回复 / Stop response, ...). It never reads text, edit or image
// elements, never descends into the conversation messages or a page from another host, never
// invokes anything, and keeps no label. Anything else (timeouts, a changed UI) reads as unknown,
// never as done.
#pragma once

#include "SignalStore.h"

#include <QString>

namespace asb::claudeui {

enum class State { NotRunning, Working, NotResponding, Unavailable };

bool isStopLabel(const QString &label);
bool isMessagesGroup(const QString &label);
QString stateKey(State state); // notRunning | working | notResponding | unavailable

// Blocking (COM, up to about a second): call it from a worker thread.
State observe();
// The session that stands in for the idle presence session while Claude replies.
SessionStatus workingSession(qint64 nowMs);

} // namespace asb::claudeui
