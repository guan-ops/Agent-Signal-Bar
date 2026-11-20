# Agent Signal Bar for Windows (Qt 6). Builds on macOS too, for development and
# --capture screenshots; the tray, backdrop and start-at-login code paths are Windows-only.
QT += core gui widgets quick qml quickcontrols2 svg
CONFIG += c++20
CONFIG -= app_bundle
TARGET = AgentSignalBar

SOURCES += src/main.cpp src/AppController.cpp src/SignalModel.cpp src/TrayIconRenderer.cpp
HEADERS += src/AppController.h src/SignalModel.h src/TrayIconRenderer.h
RESOURCES += resources.qrc

ASB_VERSION = $$(ASB_WINDOWS_VERSION)
isEmpty(ASB_VERSION): ASB_VERSION = 0.1.0
DEFINES += ASB_WINDOWS_VERSION=\\\"$$ASB_VERSION\\\"

win32 {
    CONFIG += windows
    DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
    LIBS += -ldwmapi -lwinmm -luser32
    RC_ICONS = resources/AgentSignalBar.ico
    QMAKE_TARGET_DESCRIPTION = "Agent Signal Bar"
    QMAKE_TARGET_PRODUCT = "Agent Signal Bar"
    QMAKE_TARGET_COPYRIGHT = "Copyright 2026 XiongYang Guan"
    VERSION = $$ASB_VERSION
}
!win32: QMAKE_CXXFLAGS += -Wall -Wextra
