// Installs, checks and removes the Claude Code hooks in <claude root>/settings.json. Port of
// the Claude half of NativeHookInstaller.swift:
// - only commands that run agent-signal are touched; every other setting and hook survives;
// - an existing registration that already runs this exe for all tools is kept in place;
// - missing events get one block {"matcher": "", "hooks": [{type, command, args, timeout}]};
// - the file is backed up (newest 5 .bak-* copies kept) and replaced atomically;
// - a file that does not parse, is not an object, or is a symbolic link is left untouched.
//
// Windows hook entries use the exec form (`command` = the exe, `args` = ["claude-hook"]), so
// no shell parses the path. The command string has forward slashes and, on Windows, no
// spaces (8.3 short path), so a Claude Code version that ignores `args` and runs the string
// through Git Bash or PowerShell still starts the exe; agent-signal treats "no arguments,
// piped stdin" as claude-hook.
#pragma once

#include <QString>
#include <QStringList>

namespace asb::hooks {

struct HookReport {
    bool ok = false;          // false: could not read or write (see error)
    QString error;
    QString settingsPath;
    bool configured = false;  // every event runs the current exe
    QStringList missing;      // events without a current registration
    QStringList stale;        // events with an owned registration that is not current
    bool changed = false;     // install/uninstall wrote the file
    QString backup;
};

class ClaudeHookInstaller {
public:
    ClaudeHookInstaller(QString claudeRoot, QString hookExe);

    // CLAUDE_CONFIG_DIR, else <home>/.claude.
    static QString defaultClaudeRoot(const QString &home, const QString &configDirEnv);
    // The string written as the hook's `command`.
    static QString commandPath(const QString &hookExe);
    // True when hooks pointing at this exe would break later (it runs from a temp folder).
    static bool isTemporaryLocation(const QString &hookExe);

    HookReport check() const;
    HookReport install() const;
    HookReport uninstall() const;

    static constexpr int kRetainedBackups = 5;
    // Tests keep their fake exe in a temporary directory.
    void allowTemporaryLocationForTests() { m_allowTemporary = true; }

private:
    HookReport run(bool write, bool remove) const;

    QString m_root;
    QString m_exe;
    bool m_allowTemporary = false;
};

} // namespace asb::hooks
