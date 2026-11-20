QT += core testlib
QT -= gui
CONFIG += c++20 console testcase
CONFIG -= app_bundle
TARGET = tst_codex
SOURCES += tst_codex.cpp ../src/SignalModel.cpp ../src/CodexSessionParser.cpp ../src/CodexActivityMonitor.cpp \
    ../src/SignalStore.cpp ../src/ActivityDisplay.cpp
HEADERS += ../src/SignalModel.h ../src/CodexSessionParser.h ../src/CodexActivityMonitor.h ../src/SignalStore.h \
    ../src/ActivityDisplay.h
DEFINES += CODEX_GOLDEN_PATH=\\\"$$PWD/golden/codex_golden.jsonl\\\" CODEX_LINES_PATH=\\\"$$PWD/golden/codex/lines.jsonl\\\"
