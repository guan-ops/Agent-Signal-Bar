// sign_update for Windows releases: Sparkle's sign_update / generate_keys for the Windows appcast,
// using the same Ed25519 code the app verifies with.
//
//   sign_update <file> --ed-key-file <path|->  [--expect-public-key <base64>]
//       prints: sparkle:edSignature="..." length="..."
//   sign_update --public-key --ed-key-file <path|->
//   sign_update --verify <file> <signature-base64> --public-key-value <base64>
//   sign_update --generate-keys            (a new seed and its public key, for test feeds)
//
// The key file holds SPARKLE_PRIVATE_KEY as exported by Sparkle's generate_keys -x: the base64
// 32-byte seed, or the legacy 96-byte expanded key + public key. "-" reads it from stdin.

#include "../../src/Ed25519.h"

#include <QCoreApplication>
#include <QFile>
#include <QRandomGenerator>
#include <QTextStream>

#include <cstdio>

using namespace asb;

namespace {

int fail(const QString &message) {
    QTextStream(stderr) << "sign_update: " << message << '\n';
    return 1;
}

QByteArray readKey(const QString &path, QString *error) {
    QFile file;
    const bool ok = path == "-" ? file.open(stdin, QIODevice::ReadOnly) : (file.setFileName(path), file.open(QIODevice::ReadOnly));
    if (!ok) {
        *error = "cannot read the key file " + path;
        return {};
    }
    const QByteArray text = file.readAll().trimmed();
    const auto decoded = QByteArray::fromBase64Encoding(text, QByteArray::AbortOnBase64DecodingErrors);
    if (!decoded || ed25519::publicKey(*decoded).isEmpty()) {
        *error = "the key is not a base64 Ed25519 private key (32-byte seed or 96-byte legacy export)";
        return {};
    }
    return *decoded;
}

QString value(const QStringList &args, const QString &name) {
    const qsizetype index = args.indexOf(name);
    return index >= 0 && index + 1 < args.size() ? args.at(index + 1) : QString();
}

} // namespace

int main(int argc, char *argv[]) {
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments().mid(1);
    QTextStream out(stdout);

    if (args.contains("--generate-keys")) {
        QByteArray seed(32, '\0');
        QRandomGenerator::system()->fillRange(reinterpret_cast<quint32 *>(seed.data()), 8);
        out << "private: " << seed.toBase64() << '\n' << "public:  " << ed25519::publicKey(seed).toBase64() << '\n';
        return 0;
    }
    if (args.contains("--verify")) {
        const qsizetype index = args.indexOf("--verify");
        if (index + 2 >= args.size()) return fail("--verify needs <file> <signature>");
        QFile file(args.at(index + 1));
        if (!file.open(QIODevice::ReadOnly)) return fail("cannot read " + file.fileName());
        const QByteArray signature = QByteArray::fromBase64(args.at(index + 2).toLatin1());
        const QByteArray key = QByteArray::fromBase64(value(args, "--public-key-value").toLatin1());
        if (!ed25519::verify(&file, signature, key)) return fail("the signature does not match");
        out << "OK\n";
        return 0;
    }

    const QString keyFile = value(args, "--ed-key-file");
    if (keyFile.isEmpty()) return fail("--ed-key-file <path|-> is required");
    QString error;
    const QByteArray key = readKey(keyFile, &error);
    if (key.isEmpty()) return fail(error);
    const QByteArray publicKey = ed25519::publicKey(key);
    if (args.contains("--public-key")) {
        out << publicKey.toBase64() << '\n';
        return 0;
    }
    // Refuse to sign with a key whose public half is not the one built into the app.
    const QString expected = value(args, "--expect-public-key");
    if (!expected.isEmpty() && publicKey.toBase64() != expected.toLatin1())
        return fail("the private key does not belong to the expected public key " + expected);

    QString path;
    for (qsizetype i = 0; i < args.size(); ++i) {
        if (args.at(i) == "--ed-key-file" || args.at(i) == "--expect-public-key") {
            ++i;
            continue;
        }
        if (!args.at(i).startsWith("--")) path = args.at(i);
    }
    if (path.isEmpty()) return fail("no file to sign");
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return fail("cannot read " + path);
    const QByteArray data = file.readAll();
    const QByteArray signature = ed25519::sign(data, key);
    if (signature.isEmpty() || !ed25519::verify(data, signature, publicKey)) return fail("signing failed");
    out << "sparkle:edSignature=\"" << signature.toBase64() << "\" length=\"" << data.size() << "\"\n";
    return 0;
}
