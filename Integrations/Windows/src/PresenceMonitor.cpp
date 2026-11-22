#include "PresenceMonitor.h"

#include <QDir>
#include <QFileInfo>
#include <QSet>
#include <algorithm>
#include <functional>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dwmapi.h>
#include <psapi.h>
#endif

namespace asb::presence {
namespace {

struct Definition {
    QString sessionID;
    QString agent;
    QString event;
    bool requiresVisibleWindow;
    std::function<bool(const QString &path, const QString &name)> match;
};

bool isCodexHelper(const QString &path, const QString &name) {
    return path.contains("/windowsapps/openai.codex") || path.contains("/extensions/openai.chatgpt")
        || path.contains("/.vscode/extensions/") || path.contains("/jetbrains/") || name.contains("computer-use")
        || name.contains("sandbox") || name.contains("app-server");
}

const QList<Definition> &definitions() {
    static const QList<Definition> list = {
        {"platform-presence:codex-desktop", "codex-desktop", "PlatformPresence:Desktop", true,
         [](const QString &path, const QString &name) {
             return (path.contains("/windowsapps/openai.codex_") && name == "chatgpt.exe")
                 || (path.contains("/programs/codex/") && name == "codex.exe");
         }},
        {"platform-presence:codex-cli", "codex-cli", "PlatformPresence:CLI", false,
         [](const QString &path, const QString &name) {
             return name.startsWith("codex") && name.endsWith(".exe") && !isCodexHelper(path, name);
         }},
        {"platform-presence:codex-vscode", "codex-vscode", "PlatformPresence:VSCode", false,
         [](const QString &path, const QString &name) {
             return path.contains("/extensions/openai.chatgpt")
                 || (path.contains("/.vscode/extensions/") && name.startsWith("codex"));
         }},
        {"platform-presence:codex-idea", "codex-idea", "PlatformPresence:IDEA", false,
         [](const QString &path, const QString &) { return path.contains("/jetbrains/") && path.contains("/aia/codex/"); }},
        {"platform-presence:claude-desktop", "claude-desktop", "PlatformPresence:Desktop", true,
         [](const QString &path, const QString &name) {
             return name == "claude.exe" && (path.contains("/windowsapps/claude_") || path.contains("/anthropicclaude/"))
                 && !path.contains("/claude-code/");
         }},
    };
    return list;
}

} // namespace

QList<SessionStatus> detect(const QList<ProcessInfo> &processes, qint64 now) {
    QList<SessionStatus> sessions;
    for (const Definition &d : definitions()) {
        const bool running = std::any_of(processes.cbegin(), processes.cend(), [&](const ProcessInfo &p) {
            if (d.requiresVisibleWindow && !p.hasVisibleWindow) return false;
            const QString path = QDir::fromNativeSeparators(p.path).toLower();
            return d.match(path, QFileInfo(path).fileName());
        });
        if (!running) continue;
        SessionStatus s;
        s.sessionID = d.sessionID;
        s.signal = QStringLiteral("idle");
        s.updatedAt = now;
        s.agent = d.agent;
        s.lastEvent = d.event;
        sessions.append(s);
    }
    return sessions;
}

QList<ProcessInfo> runningProcesses() {
    QList<ProcessInfo> processes;
#ifdef Q_OS_WIN
    // Owners of a window a person can see: visible, not minimised, not cloaked (another virtual
    // desktop, a suspended UWP frame), not a tool window, with a size.
    QSet<DWORD> visible;
    EnumWindows(
        [](HWND hwnd, LPARAM param) -> BOOL {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
            if (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return TRUE;
            BOOL cloaked = FALSE;
            if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked) return TRUE;
            RECT rect;
            if (!GetWindowRect(hwnd, &rect) || rect.right <= rect.left || rect.bottom <= rect.top) return TRUE;
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            reinterpret_cast<QSet<DWORD> *>(param)->insert(pid);
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&visible));

    QList<DWORD> pids(4096);
    DWORD bytes = 0;
    if (!K32EnumProcesses(pids.data(), DWORD(pids.size() * sizeof(DWORD)), &bytes)) return processes;
    pids.resize(bytes / sizeof(DWORD));
    for (DWORD pid : std::as_const(pids)) {
        if (pid == 0) continue;
        // Elevated and protected processes refuse even this; they are not agent apps.
        const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process) continue;
        wchar_t path[MAX_PATH * 2];
        DWORD size = DWORD(std::size(path));
        if (QueryFullProcessImageNameW(process, 0, path, &size))
            processes.append({QString::fromWCharArray(path, int(size)), visible.contains(pid)});
        CloseHandle(process);
    }
#endif
    return processes;
}

} // namespace asb::presence
