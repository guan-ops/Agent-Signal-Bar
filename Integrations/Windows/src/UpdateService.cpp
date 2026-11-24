#include "UpdateService.h"

#include "Ed25519.h"
#include "I18n.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QOperatingSystemVersion>
#include <QProcess>
#include <QRegularExpression>
#include <QThreadPool>
#include <QUuid>

#ifdef Q_OS_WIN
#include <windows.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#endif

using asb::i18n::text;

namespace asb::updates {

QString authenticodeSigner(const QString &path) {
#ifdef Q_OS_WIN
    const std::wstring file = QDir::toNativeSeparators(path).toStdWString();
    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = file.c_str();
    WINTRUST_DATA data{};
    data.cbStruct = sizeof(data);
    data.dwUIChoice = WTD_UI_NONE;
    data.fdwRevocationChecks = WTD_REVOKE_NONE; // works offline; the chain and timestamp still count
    data.dwUnionChoice = WTD_CHOICE_FILE;
    data.pFile = &fileInfo;
    data.dwStateAction = WTD_STATEACTION_VERIFY;
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    QString subject;
    if (WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &data) == ERROR_SUCCESS) {
        CRYPT_PROVIDER_DATA *provider = WTHelperProvDataFromStateData(data.hWVTStateData);
        CRYPT_PROVIDER_SGNR *signer = provider ? WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0) : nullptr;
        CRYPT_PROVIDER_CERT *cert = signer ? WTHelperGetProvCertFromChain(signer, 0) : nullptr;
        if (cert && cert->pCert) {
            wchar_t name[512];
            const DWORD length = CertGetNameStringW(cert->pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, name, 512);
            if (length > 1) subject = QString::fromWCharArray(name, int(length - 1));
        }
    }
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &data);
    return subject;
#else
    Q_UNUSED(path);
    return {};
#endif
}

bool canWriteTo(const QString &dir) {
    if (dir.isEmpty() || !QFileInfo(dir).isDir()) return false;
    QFile probe(QDir(dir).filePath(".asb-write-test-" + QUuid::createUuid().toString(QUuid::Id128)));
    if (!probe.open(QIODevice::WriteOnly)) return false;
    probe.close();
    probe.remove();
    return true;
}

} // namespace asb::updates

namespace {

QString fileNameFor(const QUrl &url) {
    QString name = QFileInfo(url.path()).fileName();
    name.remove(QRegularExpression(QStringLiteral(R"([^A-Za-z0-9._-])")));
    return name.isEmpty() ? QStringLiteral("AgentSignalBar-setup.exe") : name;
}

} // namespace

UpdateService::UpdateService(Config config, QObject *parent)
    : QObject(parent), m_config(std::move(config)), m_network(new QNetworkAccessManager(this)) {
    m_network->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
}

UpdateService::~UpdateService() {
    if (m_reply) m_reply->abort();
    delete m_file;
}

bool UpdateService::configured() const {
    return m_config.feedUrl.isValid() && !m_config.feedUrl.isEmpty() && m_config.publicKey.size() == 32
        && !m_config.build.isEmpty() && m_config.build != QLatin1String("0");
}

QString UpdateService::stageKey(Stage stage) {
    switch (stage) {
    case Stage::Idle: return QStringLiteral("idle");
    case Stage::Checking: return QStringLiteral("checking");
    case Stage::UpToDate: return QStringLiteral("upToDate");
    case Stage::Available: return QStringLiteral("available");
    case Stage::Downloading: return QStringLiteral("downloading");
    case Stage::Verifying: return QStringLiteral("verifying");
    case Stage::Ready: return QStringLiteral("ready");
    case Stage::Installing: return QStringLiteral("installing");
    case Stage::Failed: return QStringLiteral("failed");
    }
    return QStringLiteral("idle");
}

QString UpdateService::osVersion() {
    const QOperatingSystemVersion os = QOperatingSystemVersion::current();
    return QStringLiteral("%1.%2.%3").arg(os.majorVersion()).arg(qMax(0, os.minorVersion())).arg(qMax(0, os.microVersion()));
}

void UpdateService::setStage(Stage stage) {
    m_stage = stage;
    emit changed();
}

void UpdateService::fail(const QString &message) {
    m_error = message;
    setStage(Stage::Failed);
}

void UpdateService::check(asb::appcast::Criteria criteria) {
    if (!configured()) return;
    // A check never interrupts a download or an update that is ready to install.
    if (m_stage == Stage::Checking || m_stage == Stage::Downloading || m_stage == Stage::Verifying
        || m_stage == Stage::Installing)
        return;
    if (m_stage == Stage::Ready) {
        if (criteria.userInitiated) {
            m_userInitiated = true;
            emit checkFinished(true); // show the staged update again
        }
        return;
    }
    criteria.currentVersion = m_config.build;
    criteria.osVersion = osVersion();
    m_userInitiated = criteria.userInitiated;
    m_error.clear();
    m_item.reset();
    setStage(Stage::Checking);

    QNetworkRequest request(m_config.feedUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader, "AgentSignalBar/" + m_config.version + " (Windows)");
    request.setRawHeader("Accept", "application/rss+xml, application/xml;q=0.9, */*;q=0.1");
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setTransferTimeout(30000);
    const int generation = ++m_generation;
    QNetworkReply *reply = m_network->get(request);
    m_reply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, criteria, generation] {
        reply->deleteLater();
        if (generation != m_generation) return; // cancelled
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || (status != 0 && (status < 200 || status >= 300))) {
            fail(status >= 400 ? text("更新源返回 HTTP %1。", "The update feed returned HTTP %1.").arg(status)
                               : text("无法读取更新源：%1", "Could not read the update feed: %1").arg(reply->errorString()));
            emit checkFinished(criteria.userInitiated);
            return;
        }
        QString parseError;
        const QList<asb::appcast::Item> items = asb::appcast::parse(reply->read(8 * 1024 * 1024), &parseError);
        if (!parseError.isEmpty()) {
            fail(text("更新源格式无效：%1", "The update feed is not valid: %1").arg(parseError));
            emit checkFinished(criteria.userInitiated);
            return;
        }
        m_item = asb::appcast::bestUpdate(items, criteria);
        setStage(m_item ? Stage::Available : Stage::UpToDate);
        emit checkFinished(criteria.userInitiated);
    });
}

void UpdateService::download() {
    if (m_stage != Stage::Available || !m_item || m_item->informational) return;
    // The folder is named after the feed's version: never let it leave the cache folder.
    QString folder = m_item->version;
    folder.remove(QRegularExpression(QStringLiteral(R"([^A-Za-z0-9._-])")));
    if (folder.isEmpty() || folder.contains(QLatin1String(".."))) folder = QStringLiteral("update");
    const QString dir = QDir(m_config.cacheDir).filePath(folder);
    if (!QDir().mkpath(dir)) {
        fail(text("无法创建下载文件夹：%1", "Could not create the download folder: %1").arg(QDir::toNativeSeparators(dir)));
        return;
    }
    clearOldDownloads(folder);
    const QString path = QDir(dir).filePath(fileNameFor(m_item->url));
    if (!path.endsWith(QLatin1String(".exe"), Qt::CaseInsensitive)) {
        fail(text("更新文件不是 Windows 安装程序。", "The update is not a Windows installer."));
        return;
    }
    QFile::remove(path);
    delete m_file;
    m_file = new QFile(path + ".part");
    if (!m_file->open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        fail(text("无法写入下载文件：%1", "Could not write the download: %1").arg(m_file->errorString()));
        return;
    }
    m_received = 0;
    m_total = qMax<qint64>(0, m_item->length);
    m_error.clear();
    setStage(Stage::Downloading);

    QNetworkRequest request(m_item->url);
    request.setHeader(QNetworkRequest::UserAgentHeader, "AgentSignalBar/" + m_config.version + " (Windows)");
    request.setTransferTimeout(60000); // without data for a minute
    const int generation = ++m_generation;
    QNetworkReply *reply = m_network->get(request);
    m_reply = reply;
    connect(reply, &QNetworkReply::readyRead, this, [this, reply, generation] {
        if (generation != m_generation || !m_file) return;
        const QByteArray chunk = reply->readAll();
        if (m_file->write(chunk) != chunk.size()) {
            reply->abort();
            return;
        }
        m_received += chunk.size();
        // A length well beyond the feed's says this is not the signed file.
        if (m_item && m_item->length > 0 && m_received > m_item->length) reply->abort();
    });
    connect(reply, &QNetworkReply::downloadProgress, this, [this, generation](qint64 received, qint64 total) {
        if (generation != m_generation) return;
        if (total > 0) m_total = total;
        Q_UNUSED(received);
        emit changed();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation] {
        reply->deleteLater();
        if (generation != m_generation) return;
        if (m_file && reply->isOpen() && reply->bytesAvailable() > 0) m_file->write(reply->readAll());
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool ok = reply->error() == QNetworkReply::NoError && (status == 0 || (status >= 200 && status < 300));
        const QString message = status >= 400 ? text("下载返回 HTTP %1。", "The download returned HTTP %1.").arg(status)
                                              : text("下载失败：%1", "The download failed: %1").arg(reply->errorString());
        if (!ok) {
            if (m_file) {
                m_file->close();
                m_file->remove();
            }
            fail(m_item && m_item->length > 0 && m_received > m_item->length
                     ? text("下载的文件比更新源记录的大，已丢弃。", "The download is larger than the feed says; it was discarded.")
                     : message);
            return;
        }
        finishDownload();
    });
}

void UpdateService::finishDownload() {
    const QString part = m_file->fileName();
    const QString path = part.left(part.size() - 5);
    const bool flushed = m_file->flush();
    m_file->close();
    delete m_file;
    m_file = nullptr;
    if (!flushed || !QFile::rename(part, path)) {
        QFile::remove(part);
        fail(text("无法保存下载的文件。", "Could not save the downloaded file."));
        return;
    }
    verify(path);
}

void UpdateService::verify(const QString &path) {
    setStage(Stage::Verifying);
    const qint64 expectedLength = m_item ? m_item->length : -1;
    const QByteArray signature = m_item ? m_item->edSignature : QByteArray();
    const QByteArray key = m_config.publicKey;
    const QString runningApp = QCoreApplication::applicationFilePath();
    const int generation = m_generation;
    QPointer<UpdateService> self(this);
    // Hashing a large installer takes a moment; keep it off the UI thread.
    QThreadPool::globalInstance()->start([self, path, expectedLength, signature, key, runningApp, generation] {
        QString problem;
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            problem = text("无法读取下载的文件。", "Could not read the downloaded file.");
        } else if (expectedLength > 0 && file.size() != expectedLength) {
            problem = text("下载的文件大小与更新源不符（%1，应为 %2）。", "The download's size does not match the feed (%1, expected %2).")
                          .arg(file.size()).arg(expectedLength);
        } else if (!asb::ed25519::verify(&file, signature, key)) {
            problem = text("更新的 EdDSA 签名无效，已丢弃。", "The update's EdDSA signature is not valid; it was discarded.");
        }
        file.close();
        if (problem.isEmpty()) {
            // A signed app only accepts an installer from the same publisher (Sparkle's code-signing check).
            const QString current = asb::updates::authenticodeSigner(runningApp);
            if (!current.isEmpty() && asb::updates::authenticodeSigner(path) != current)
                problem = text("安装程序的代码签名与当前应用不一致，已丢弃。",
                               "The installer is not code-signed by the same publisher as this app; it was discarded.");
        }
        if (!problem.isEmpty()) QFile::remove(path);
        QMetaObject::invokeMethod(qApp, [self, path, problem, generation] {
            if (!self || generation != self->m_generation) return;
            if (!problem.isEmpty()) {
                self->fail(problem);
                return;
            }
            self->m_installer = path;
            self->setStage(Stage::Ready);
            emit self->readyToInstall();
        });
    });
}

void UpdateService::cancel() {
    ++m_generation;
    if (m_reply) m_reply->abort();
    if (m_file) {
        m_file->close();
        m_file->remove();
        delete m_file;
        m_file = nullptr;
    }
    m_item.reset();
    m_error.clear();
    setStage(Stage::Idle);
}

void UpdateService::dismiss() {
    if (m_stage == Stage::Ready || m_stage == Stage::Downloading || m_stage == Stage::Verifying
        || m_stage == Stage::Installing)
        return; // a download carries on; a ready update stays staged
    m_error.clear();
    setStage(Stage::Idle);
}

bool UpdateService::install(bool relaunch) {
    if (m_stage != Stage::Ready || m_installer.isEmpty() || !QFileInfo::exists(m_installer)) return false;
    if (!asb::updates::canWriteTo(m_config.appDir)) {
        fail(text("没有权限写入 %1，请从下载页面获取安装程序。", "Cannot write to %1; get the installer from the download page.")
                 .arg(QDir::toNativeSeparators(m_config.appDir)));
        return false;
    }
    const QStringList arguments = {
        QStringLiteral("/VERYSILENT"), QStringLiteral("/SUPPRESSMSGBOXES"), QStringLiteral("/NORESTART"),
        QStringLiteral("/SP-"), QStringLiteral("/UPDATE=1"),
        relaunch ? QStringLiteral("/RELAUNCH=1") : QStringLiteral("/RELAUNCH=0"),
        "/DIR=" + QDir::toNativeSeparators(m_config.appDir),
        "/LOG=" + QDir::toNativeSeparators(QDir(m_config.cacheDir).filePath("install.log"))};
    if (!QProcess::startDetached(m_installer, arguments, QFileInfo(m_installer).absolutePath())) {
        fail(text("无法启动安装程序。", "Could not start the installer."));
        return false;
    }
    setStage(Stage::Installing);
    return true;
}

void UpdateService::clearOldDownloads(const QString &keep) const {
    QDir cache(m_config.cacheDir);
    for (const QString &entry : cache.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        if (entry != keep) QDir(cache.filePath(entry)).removeRecursively();
    }
}
