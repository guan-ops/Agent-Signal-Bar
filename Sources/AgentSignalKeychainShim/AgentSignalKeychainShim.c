#include "AgentSignalKeychainShim.h"
#include <Security/Security.h>

// SecKeychain{Get,Set}UserInteractionAllowed are deprecated since macOS 10.10 but remain the
// only way to make file-based keychain ACL checks fail closed instead of showing a dialog.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OSStatus ASLLegacyKeychainGetUserInteractionAllowed(bool *allowed) {
    Boolean value = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&value);
    if (status == errSecSuccess) { *allowed = value != 0; }
    return status;
}

OSStatus ASLLegacyKeychainSetUserInteractionAllowed(bool allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed ? true : false);
}

#pragma clang diagnostic pop
