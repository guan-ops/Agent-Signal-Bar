# sign_update: signs the Windows installer for the appcast (package.ps1, release workflow).
QT = core
CONFIG += c++20 console
CONFIG -= app_bundle
TARGET = sign_update
SOURCES += sign_update.cpp ../../src/Ed25519.cpp
HEADERS += ../../src/Ed25519.h
