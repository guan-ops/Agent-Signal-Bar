// Which agent apps are running, as idle "presence" sessions. Port of
// CodexPlatformPresenceMonitor.swift for Windows: macOS reads bundle identifiers, visible windows
// and `ps` command lines; Windows reads each process's executable path (no command lines needed)
// and which processes own a visible, uncloaked, non-minimised top-level window.
//
//   Codex desktop  WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe (or ...\Programs\Codex\Codex.exe),
//                  with a visible window
//   Codex CLI      codex*.exe anywhere else (npm vendor binary, winget, scoop), except the
//                  desktop app's own helpers, editor extensions and JetBrains
//   Codex VS Code  the openai.chatgpt extension's codex.exe
//   Codex IDEA     JetBrains AI Assistant's ...\aia\codex\ binary
//   Claude desktop WindowsApps\Claude_*\app\claude.exe or AnthropicClaude\app-*\claude.exe, with
//                  a visible window (not the Claude Code binary it ships)
#pragma once

#include "SignalStore.h"

#include <QList>
#include <QString>

namespace asb::presence {

struct ProcessInfo {
    QString path;              // full executable path
    bool hasVisibleWindow = false;
};

// One idle session per platform found running (sessionID platform-presence:<agent>,
// lastEvent PlatformPresence:<kind>), as on macOS.
QList<SessionStatus> detect(const QList<ProcessInfo> &processes, qint64 now);
// The processes running now (Windows; empty elsewhere).
QList<ProcessInfo> runningProcesses();

} // namespace asb::presence
