// The optional debug log (Settings → Debug → Logs), like MenuBarStatusModel's appendDebugLog:
// %LOCALAPPDATA%\AgentSignalBar\debug.log, one "[date time] message" line per entry.
//
// Windows also routes Qt's own messages there while logging is on, filtered by the level:
// "error" keeps warnings and errors, "info" adds info messages, "verbose" adds debug messages
// and turns on the asb.* debug categories (sound cues, ...). The file starts over as
// debug.log.1 once it passes 2 MiB, so it cannot grow without bound.
#pragma once

#include <QString>

namespace asb::debuglog {

QString path();
// Off: nothing is written. Messages keep going to the previous handler (the debugger) too.
void configure(bool enabled, const QString &level);
bool enabled();
// An app event, written only while logging is on.
void append(const QString &message);
// The whole file ("" when there is none).
QString readAll();
// Creates the file with its header when missing, so it can be opened.
void ensureExists();

} // namespace asb::debuglog
