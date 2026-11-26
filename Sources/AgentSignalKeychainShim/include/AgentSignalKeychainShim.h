#ifndef AGENT_SIGNAL_KEYCHAIN_SHIM_H
#define AGENT_SIGNAL_KEYCHAIN_SHIM_H

#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

/// Reads the process-wide legacy keychain interaction flag.
/// Apple has no non-deprecated equivalent: LAContext.interactionNotAllowed and
/// kSecUseAuthenticationContext do not suppress the file-based login keychain's ACL
/// ("allow access") dialogs. The deprecated call is kept here, in one C file, so the
/// warning is silenced in exactly one reviewed place instead of across the Swift build.
OSStatus ASLLegacyKeychainGetUserInteractionAllowed(bool *allowed);

/// Sets the process-wide legacy keychain interaction flag. See the note above.
OSStatus ASLLegacyKeychainSetUserInteractionAllowed(bool allowed);

CF_ASSUME_NONNULL_END

#endif
