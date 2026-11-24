# agent-signal.exe: the hook command and CLI (port of AgentSignalCLIMain). QtCore only,
# console subsystem: agent hooks start it on every tool call.
QT = core
CONFIG += c++20 console exceptions
CONFIG -= app_bundle
TARGET = agent-signal
SOURCES += agent_signal.cpp ../src/ClaudeHookInstaller.cpp ../src/HookAdapters.cpp ../src/SignalModel.cpp \
    ../src/SignalStore.cpp ../src/SignalStateFile.cpp
HEADERS += ../src/ClaudeHookInstaller.h ../src/HookAdapters.h ../src/SignalModel.h ../src/SignalStore.h \
    ../src/SignalStateFile.h
win32: DEFINES += NOMINMAX WIN32_LEAN_AND_MEAN
!win32: QMAKE_CXXFLAGS += -Wall -Wextra
