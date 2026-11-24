// Export diagnostics (Settings → Connect), the Windows counterpart of script/export_diagnostics.sh:
// a folder agent-signal-diagnostics-<date>-<time> under %LOCALAPPDATA%\AgentSignalBar\Diagnostics
// with
//   commands/  system.txt, agent-signal status (text and --json), install-hooks --dry-run
//   files/     status.json, debug.log (and debug.log.1)
//   config/    settings.ini (the app's preferences)
//   manifest.json
// zipped next to it with Windows' own tar.exe. Like macOS it copies no hook config files and no
// environment dump: the dry run shows the hook state instead.
#pragma once

#include <QString>
#include <QStringList>

namespace asb::diagnostics {

struct Request {
    QString outputRoot;  // ...\Diagnostics
    QString cliExe;      // agent-signal.exe; its commands are captured
    QString stateFile;   // passed to the CLI, copied to files/
    QString settingsFile;
    QString logFile;
    QStringList systemLines; // app version, OS, Qt (gathered on the GUI thread)
};

struct Result {
    bool ok = false;
    QString folder;
    QString archive; // empty when zipping failed (the folder is still complete)
    QString error;
};

// Blocking (runs agent-signal.exe and tar.exe): call it from a worker thread.
Result exportBundle(const Request &request);

} // namespace asb::diagnostics
