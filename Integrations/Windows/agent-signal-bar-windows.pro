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
    src/UsageService.cpp src/I18n.cpp src/Secrets.cpp src/CodexAccounts.cpp src/QuotaFetcher.cpp src/QuotaService.cpp src/ClaudeUiMonitor.cpp \
    src/Ed25519.cpp src/Appcast.cpp src/UpdateService.cpp
HEADERS += src/AppController.h src/SignalModel.h src/TrayIconRenderer.h \
    src/CodexSessionParser.h src/CodexActivityMonitor.h src/SignalStore.h src/ActivityDisplay.h \
    src/ActivityText.h src/SignalRuntime.h src/SignalStateFile.h src/HookAdapters.h src/ClaudeHookInstaller.h \
    src/SoundFile.h src/LightScope.h src/PresenceMonitor.h src/DebugLog.h src/Diagnostics.h src/CliPath.h \
    src/UsagePricing.h src/UsageScanner.h src/UsageService.h src/I18n.h src/Secrets.h src/CodexAccounts.h src/QuotaFetcher.h src/QuotaService.h src/ClaudeUiMonitor.h \
    src/Ed25519.h src/Appcast.h src/UpdateService.h
RESOURCES += resources.qrc

ASB_VERSION = $$(ASB_WINDOWS_VERSION)
isEmpty(ASB_VERSION): ASB_VERSION = 0.1.0
DEFINES += ASB_WINDOWS_VERSION=\\\"$$ASB_VERSION\\\"
# Release builds (package.ps1): the build number Sparkle compares (sparkle:version), the appcast URL
# and the EdDSA public key (SUFeedURL, SUPublicEDKey). Left empty, the updater stays off.
ASB_BUILD = $$(ASB_WINDOWS_BUILD)
isEmpty(ASB_BUILD): ASB_BUILD = 0
DEFINES += ASB_WINDOWS_BUILD=\\\"$$ASB_BUILD\\\"
ASB_FEED = $$(ASB_WINDOWS_UPDATE_FEED)
!isEmpty(ASB_FEED): DEFINES += ASB_UPDATE_FEED_URL=\\\"$$ASB_FEED\\\"
ASB_KEY = $$(ASB_WINDOWS_UPDATE_PUBLIC_KEY)
!isEmpty(ASB_KEY): DEFINES += ASB_UPDATE_PUBLIC_KEY=\\\"$$ASB_KEY\\\"

win32 {
    CONFIG += windows
    DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
    LIBS += -ldwmapi -lwinmm -luser32 -ladvapi32 -lcrypt32 -lole32 -loleaut32 -lwintrust
    RC_ICONS = resources/AgentSignalBar.ico
    QMAKE_TARGET_DESCRIPTION = "Agent Signal Bar"
    QMAKE_TARGET_PRODUCT = "Agent Signal Bar"
    QMAKE_TARGET_COPYRIGHT = "Copyright 2026 XiongYang Guan"
    # Braces: qmake variable names may contain dots ($$ASB_VERSION.x would name "ASB_VERSION.").
    VERSION = $${ASB_VERSION}.$${ASB_BUILD}
}
!win32: QMAKE_CXXFLAGS += -Wall -Wextra
