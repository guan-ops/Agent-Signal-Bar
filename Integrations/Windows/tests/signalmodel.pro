QT += core testlib
QT -= gui
CONFIG += c++20 console testcase
CONFIG -= app_bundle
TARGET = tst_signalmodel
SOURCES += tst_signalmodel.cpp ../src/SignalModel.cpp
HEADERS += ../src/SignalModel.h
DEFINES += GOLDEN_PATH=\\\"$$PWD/golden/lamp_golden.jsonl\\\"
