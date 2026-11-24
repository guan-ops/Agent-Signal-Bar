# gui: QuotaService opens the Codex sign-in page with QDesktopServices.
QT += core gui testlib network
CONFIG += c++20 console testcase
CONFIG -= app_bundle
TARGET = tst_codex
SOURCES += tst_codex.cpp ../src/SignalModel.cpp ../src/CodexSessionParser.cpp ../src/CodexActivityMonitor.cpp \
    ../src/SignalStore.cpp ../src/ActivityDisplay.cpp ../src/SignalStateFile.cpp ../src/HookAdapters.cpp \
    ../src/ClaudeHookInstaller.cpp ../src/SoundFile.cpp ../src/LightScope.cpp ../src/PresenceMonitor.cpp \
    ../src/CliPath.cpp ../src/UsagePricing.cpp ../src/UsageScanner.cpp ../src/I18n.cpp ../src/Secrets.cpp ../src/CodexAccounts.cpp ../src/QuotaFetcher.cpp ../src/ClaudeUiMonitor.cpp \
    ../src/Ed25519.cpp ../src/Appcast.cpp ../src/UpdateService.cpp ../src/QuotaService.cpp
HEADERS += ../src/SignalModel.h ../src/CodexSessionParser.h ../src/CodexActivityMonitor.h ../src/SignalStore.h \
    ../src/ActivityDisplay.h ../src/SignalStateFile.h ../src/HookAdapters.h ../src/ClaudeHookInstaller.h \
    ../src/SoundFile.h ../src/LightScope.h ../src/PresenceMonitor.h ../src/CliPath.h \
    ../src/UsagePricing.h ../src/UsageScanner.h ../src/I18n.h ../src/Secrets.h ../src/CodexAccounts.h ../src/QuotaFetcher.h ../src/ClaudeUiMonitor.h \
    ../src/Ed25519.h ../src/Appcast.h ../src/UpdateService.h ../src/QuotaService.h
win32: DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
win32: LIBS += -ldwmapi -luser32 -ladvapi32 -lcrypt32 -lole32 -loleaut32 -lwintrust
DEFINES += CODEX_GOLDEN_PATH=\\\"$$PWD/golden/codex_golden.jsonl\\\" CODEX_LINES_PATH=\\\"$$PWD/golden/codex/lines.jsonl\\\" \
    CLAUDE_PAYLOADS_PATH=\\\"$$PWD/golden/codex/claude_payloads.jsonl\\\" SWIFT_STATUS_PATH=\\\"$$PWD/golden/codex/swift_status.json\\\" \
    TRANSLATIONS_PATH=\\\"$$PWD/../translations.json\\\"
