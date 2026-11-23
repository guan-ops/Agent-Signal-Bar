# Agent Signal Bar for Windows (Qt 6). Builds on macOS too, for development and
# --capture screenshots; the tray, backdrop and start-at-login code paths are Windows-only.
QT += core gui widgets quick qml quickcontrols2 svg network
CONFIG += c++20
CONFIG -= app_bundle
TARGET = AgentSignalBar

SOURCES += src/main.cpp src/AppController.cpp src/SignalModel.cpp src/TrayIconRenderer.cpp \
    src/CodexSessionParser.cpp src/CodexActivityMonitor.cpp src/SignalStore.cpp src/ActivityDisplay.cpp \
    src/ActivityText.cpp src/SignalRuntime.cpp src/SignalStateFile.cpp src/HookAdapters.cpp \
    src/ClaudeHookInstaller.cpp src/SoundFile.cpp src/LightScope.cpp src/PresenceMonitor.cpp \
    src/DebugLog.cpp src/Diagnostics.cpp src/CliPath.cpp src/UsagePricing.cpp src/UsageScanner.cpp \
    src/UsageService.cpp src/I18n.cpp src/Secrets.cpp src/CodexAccounts.cpp src/QuotaFetcher.cpp src/QuotaService.cpp src/ClaudeUiMonitor.cpp
HEADERS += src/AppController.h src/SignalModel.h src/TrayIconRenderer.h \
    src/CodexSessionParser.h src/CodexActivityMonitor.h src/SignalStore.h src/ActivityDisplay.h \
    src/ActivityText.h src/SignalRuntime.h src/SignalStateFile.h src/HookAdapters.h src/ClaudeHookInstaller.h \
    src/SoundFile.h src/LightScope.h src/PresenceMonitor.h src/DebugLog.h src/Diagnostics.h src/CliPath.h \
    src/UsagePricing.h src/UsageScanner.h src/UsageService.h src/I18n.h src/Secrets.h src/CodexAccounts.h src/QuotaFetcher.h src/QuotaService.h src/ClaudeUiMonitor.h
RESOURCES += resources.qrc

ASB_VERSION = $$(ASB_WINDOWS_VERSION)
isEmpty(ASB_VERSION): ASB_VERSION = 0.1.0
DEFINES += ASB_WINDOWS_VERSION=\\\"$$ASB_VERSION\\\"

win32 {
    CONFIG += windows
    DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
    LIBS += -ldwmapi -lwinmm -luser32 -ladvapi32 -lcrypt32 -lole32 -loleaut32
    RC_ICONS = resources/AgentSignalBar.ico
    QMAKE_TARGET_DESCRIPTION = "Agent Signal Bar"
    QMAKE_TARGET_PRODUCT = "Agent Signal Bar"
    QMAKE_TARGET_COPYRIGHT = "Copyright 2026 XiongYang Guan"
    VERSION = $$ASB_VERSION
}
!win32: QMAKE_CXXFLAGS += -Wall -Wextra
