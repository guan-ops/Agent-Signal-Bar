# agent-signal.exe: the Claude Code hook command. QtCore only, console subsystem.
QT = core
CONFIG += c++20 console
CONFIG -= app_bundle
TARGET = agent-signal
SOURCES += agent_signal.cpp ../src/HookAdapters.cpp ../src/SignalModel.cpp ../src/SignalStore.cpp \
    ../src/SignalStateFile.cpp
HEADERS += ../src/HookAdapters.h ../src/SignalModel.h ../src/SignalStore.h ../src/SignalStateFile.h
win32: DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
!win32: QMAKE_CXXFLAGS += -Wall -Wextra
