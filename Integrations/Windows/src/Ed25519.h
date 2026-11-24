#pragma once

#include <QByteArray>

class QIODevice;

// Ed25519 as Sparkle uses it for update signatures (sparkle:edSignature over the whole update
// file, SUPublicEDKey as the 32-byte public key). Field and group arithmetic follow TweetNaCl
// (public domain); hashing uses QCryptographicHash::Sha512.
namespace asb::ed25519 {

// A private key in any format Sparkle's generate_keys exports: the 32-byte seed, the 64-byte
// expanded key, or the legacy 96 bytes (expanded key followed by the public key).
// Returns the 32-byte public key, or empty for another size or an inconsistent legacy key.
QByteArray publicKey(const QByteArray &privateKey);

// The 64-byte signature of `message`, or empty when the private key is unusable.
QByteArray sign(const QByteArray &message, const QByteArray &privateKey);

// RFC 8032 verification (S must be below the group order).
bool verify(const QByteArray &message, const QByteArray &signature, const QByteArray &publicKey);
// The same over a device read from its current position to the end, without holding it in memory.
bool verify(QIODevice *message, const QByteArray &signature, const QByteArray &publicKey);

} // namespace asb::ed25519
