#include "ClaudeUiMonitor.h"

#include <QDir>
#include <QElapsedTimer>
#include <QList>
#include <QSet>
#include <QUrl>

#ifdef Q_OS_WIN
#include <windows.h>
#include <ole2.h>
#include <UIAutomation.h>
#endif

namespace asb::claudeui {

bool isStopLabel(const QString &label) {
    static const QSet<QString> labels = {QStringLiteral("停止回复"), QStringLiteral("停止回覆"), QStringLiteral("停止回应"),
                                         QStringLiteral("stop response"), QStringLiteral("stop generating"),
                                         QStringLiteral("stop responding")};
    return labels.contains(label.trimmed().toLower());
}

bool isMessagesGroup(const QString &label) {
    static const QSet<QString> labels = {QStringLiteral("对话消息"), QStringLiteral("對話訊息"),
                                         QStringLiteral("conversation messages"), QStringLiteral("chat messages")};
    return labels.contains(label.trimmed().toLower());
}

QString stateKey(State state) {
    switch (state) {
    case State::NotRunning: return QStringLiteral("notRunning");
    case State::Working: return QStringLiteral("working");
    case State::NotResponding: return QStringLiteral("notResponding");
    case State::Unavailable: return QStringLiteral("unavailable");
    }
    return QStringLiteral("unavailable");
}

SessionStatus workingSession(qint64 nowMs) {
    SessionStatus s;
    s.sessionID = QStringLiteral("claude-desktop:ui");
    s.signal = QStringLiteral("working");
    s.agent = QStringLiteral("claude-desktop");
    s.lastEvent = QStringLiteral("DesktopUI:Working");
    s.updatedAt = nowMs;
    return s;
}

#ifdef Q_OS_WIN
namespace {

template <typename T>
struct Com {
    T *p = nullptr;
    ~Com() {
        if (p) p->Release();
    }
    T **out() { return &p; }
    T *operator->() const { return p; }
    explicit operator bool() const { return p != nullptr; }
};

QString bstr(BSTR value) {
    const QString text = value ? QString::fromWCharArray(value, int(SysStringLen(value))) : QString();
    if (value) SysFreeString(value);
    return text;
}

// The windows of Claude desktop (the presence rule: claude.exe of the Store or Squirrel install).
QList<HWND> claudeWindows() {
    QList<HWND> windows;
    EnumWindows(
        [](HWND hwnd, LPARAM param) -> BOOL {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
            if (!process) return TRUE;
            wchar_t path[MAX_PATH * 2];
            DWORD size = DWORD(std::size(path));
            const bool ok = QueryFullProcessImageNameW(process, 0, path, &size);
            CloseHandle(process);
            if (!ok) return TRUE;
            const QString p = QDir::fromNativeSeparators(QString::fromWCharArray(path, int(size))).toLower();
            if (p.endsWith("/claude.exe") && (p.contains("/windowsapps/claude_") || p.contains("/anthropicclaude/"))
                && !p.contains("/claude-code/"))
                reinterpret_cast<QList<HWND> *>(param)->append(hwnd);
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&windows));
    return windows;
}

struct Scan {
    IUIAutomationTreeWalker *walker = nullptr;
    QElapsedTimer clock;
    int nodes = 0;
    bool sawPage = false;
    bool complete = true;
};

constexpr int kMaxNodes = 1500;
constexpr int kMaxDepth = 24;
constexpr qint64 kDeadlineMs = 1000;

// Breadth-first over one window; true as soon as the stop button is found.
bool scanWindow(IUIAutomation *automation, HWND hwnd, Scan &scan) {
    Com<IUIAutomationElement> root;
    if (FAILED(automation->ElementFromHandle(hwnd, root.out())) || !root) {
        scan.complete = false;
        return false;
    }
    struct Item {
        IUIAutomationElement *element;
        int depth;
        bool inPage;
    };
    QList<Item> queue;
    root->AddRef();
    queue.append({root.p, 0, false});
    bool found = false;
    for (qsizetype i = 0; i < queue.size(); ++i) {
        Item item = queue.at(i);
        if (found || scan.nodes >= kMaxNodes || scan.clock.elapsed() > kDeadlineMs) {
            if (!found) scan.complete = false;
            continue; // release below
        }
        ++scan.nodes;
        CONTROLTYPEID type = 0;
        item.element->get_CurrentControlType(&type);
        // Text, edit and image elements hold message and composer text: never touch them.
        if (type == UIA_TextControlTypeId || type == UIA_EditControlTypeId || type == UIA_ImageControlTypeId) continue;
        BSTR rawName = nullptr;
        item.element->get_CurrentName(&rawName);
        const QString name = bstr(rawName);
        bool inPage = item.inPage;
        if (type == UIA_DocumentControlTypeId) {
            // Chromium exposes a page's URL as the document's value; only its host is kept.
            Com<IUIAutomationValuePattern> value;
            QString host;
            if (SUCCEEDED(item.element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(value.out()))) && value) {
                BSTR rawUrl = nullptr;
                value->get_CurrentValue(&rawUrl);
                host = QUrl(bstr(rawUrl)).host().toLower();
            }
            if (host != "claude.ai") continue; // another site (artifacts, embeds) cannot spoof the state
            inPage = true;
            scan.sawPage = true;
        }
        if (type == UIA_GroupControlTypeId && isMessagesGroup(name)) continue;
        if (inPage && type == UIA_ButtonControlTypeId && isStopLabel(name)) {
            BOOL enabled = FALSE;
            item.element->get_CurrentIsEnabled(&enabled);
            if (enabled) {
                found = true;
                continue;
            }
        }
        if (item.depth + 1 >= kMaxDepth) continue;
        IUIAutomationElement *child = nullptr;
        scan.walker->GetFirstChildElement(item.element, &child);
        while (child) {
            queue.append({child, item.depth + 1, inPage});
            IUIAutomationElement *next = nullptr;
            scan.walker->GetNextSiblingElement(child, &next);
            child = next;
            if (queue.size() > kMaxNodes * 4) break;
        }
    }
    for (const Item &item : queue) item.element->Release();
    return found;
}

} // namespace

State observe() {
    const QList<HWND> windows = claudeWindows();
    if (windows.isEmpty()) return State::NotRunning;
    const HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    State state = State::Unavailable;
    {
        Com<IUIAutomation> automation;
        if (SUCCEEDED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation),
                                       reinterpret_cast<void **>(automation.out())))
            && automation) {
            Com<IUIAutomationTreeWalker> walker;
            if (SUCCEEDED(automation->get_RawViewWalker(walker.out())) && walker) {
                Scan scan;
                scan.walker = walker.p;
                scan.clock.start();
                bool working = false;
                for (HWND hwnd : windows) {
                    if (scanWindow(automation.p, hwnd, scan)) {
                        working = true;
                        break;
                    }
                }
                state = working ? State::Working
                    : (scan.sawPage && scan.complete) ? State::NotResponding : State::Unavailable;
            }
        }
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return state;
}
#else
State observe() { return State::NotRunning; }
#endif

} // namespace asb::claudeui
