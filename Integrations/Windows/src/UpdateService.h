#pragma once

#include "Appcast.h"

#include <QByteArray>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QUrl>

#include <optional>

class QFile;
class QNetworkAccessManager;
class QNetworkReply;

// The Windows counterpart of Sparkle's updater (SPUStandardUpdaterController on macOS):
// reads the appcast from GitHub Releases, downloads the newest Windows installer, checks its
// EdDSA signature against the public key built into the app (and, when this app is
// Authenticode-signed, that the installer has the same signer), then runs the installer
// silently and lets it relaunch the app. Preferences and scheduling live in AppController.
class UpdateService : public QObject {
    Q_OBJECT
public:
    struct Config {
        QUrl feedUrl;
        QByteArray publicKey; // 32 bytes (SUPublicEDKey, decoded)
        QString version;      // "1.7.0"
        QString build;        // "24", compared with sparkle:version
        QString cacheDir;     // downloads go to <cacheDir>/<build>/
        QString appDir;       // where the running app is installed
    };
    enum class Stage { Idle, Checking, UpToDate, Available, Downloading, Verifying, Ready, Installing, Failed };

    explicit UpdateService(Config config, QObject *parent = nullptr);
    ~UpdateService() override;

    // A release build: a feed URL and a valid public key were built in.
    bool configured() const;
    Stage stage() const { return m_stage; }
    const Config &config() const { return m_config; }
    const std::optional<asb::appcast::Item> &item() const { return m_item; }
    bool userInitiated() const { return m_userInitiated; }
    qint64 received() const { return m_received; }
    qint64 total() const { return m_total; }
    QString error() const { return m_error; }
    QString installerPath() const { return m_installer; }

    // `criteria.currentVersion` and `osVersion` are filled in here.
    void check(asb::appcast::Criteria criteria);
    void download();
    // Stops a check or download and forgets the found update.
    void cancel();
    // "Remind Me Later": back to idle, but a downloaded update stays ready to install.
    void dismiss();
    // Starts the verified installer silently; it waits for this app to exit, installs over
    // appDir and, with `relaunch`, starts the app again. True when the installer started, after
    // which the caller quits.
    bool install(bool relaunch);

    static QString stageKey(Stage stage);
    // "10.0.26100": what sparkle:minimumSystemVersion is compared with.
    static QString osVersion();

signals:
    void changed();
    // A check ended (Available, UpToDate or Failed).
    void checkFinished(bool userInitiated);
    void readyToInstall();

private:
    void setStage(Stage stage);
    void fail(const QString &message);
    void finishDownload();
    void verify(const QString &path);
    void clearOldDownloads(const QString &keep) const;

    Config m_config;
    QNetworkAccessManager *m_network = nullptr;
    QPointer<QNetworkReply> m_reply;
    QFile *m_file = nullptr;
    Stage m_stage = Stage::Idle;
    std::optional<asb::appcast::Item> m_item;
    bool m_userInitiated = false;
    qint64 m_received = 0;
    qint64 m_total = 0;
    QString m_error;
    QString m_installer;
    int m_generation = 0; // ignores verification results from a cancelled download
};

namespace asb::updates {
// The leaf certificate's name when `path` has a valid Authenticode signature, else empty.
QString authenticodeSigner(const QString &path);
// Whether a new file can be created in `dir` (the installer runs without elevation).
bool canWriteTo(const QString &dir);
} // namespace asb::updates
