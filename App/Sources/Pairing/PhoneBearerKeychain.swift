import Foundation
import Security

/// Keychain-backed storage for the `phone_bearer` token.
///
/// Lane 11 (audit-r14) hardening — the bearer used to live in
/// `UserDefaults` (`ConnectionStore.swift:67-69` in v2026.5.38), which
/// is unencrypted at rest on iOS and survives app uninstall + restore
/// on the same Apple ID. Moving to Keychain with
/// ``kSecClassGenericPassword`` + ``kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly``
/// gives us:
///
/// * AES-256 encryption at rest (Keychain class B).
/// * Wipes on uninstall (Keychain inherits the app's bundle scope).
/// * Cannot be read while the device is locked (the bearer is only
///   ever consumed by the WebSocket dial, which happens after the
///   user has unlocked the device to launch the app).
/// * Cannot be migrated to a different physical device via iCloud
///   restore (``ThisDeviceOnly`` flag — the brain pairs per-device).
///
/// The class is deliberately namespaced under ``ai.feral.companion``
/// so the bearer doesn't collide with any other Keychain item the
/// host app might store (CallKit, Apple Music, etc.). On test injection
/// the call site can pass a custom ``account`` so tests stay
/// hermetic.
enum PhoneBearerKeychain {

    static let service = "ai.feral.companion.phone_bearer"
    static let defaultAccount = "primary"

    /// Persist a bearer. Overwrites any existing entry under the same
    /// ``account``. Returns ``true`` on success — failures are logged
    /// to ``DebugLog`` so the operator can see a Keychain ACL miss
    /// without attaching to Xcode.
    @discardableResult
    static func save(_ bearer: String, account: String = defaultAccount) -> Bool {
        guard let data = bearer.data(using: .utf8) else { return false }

        // Delete any prior entry first — SecItemUpdate requires a
        // pre-existing item AND a separate attribute dict for the
        // update payload; delete+add keeps the call site one branch.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            #if DEBUG
            NSLog("[FERAL][KEYCHAIN] save failed: %d", Int(status))
            #endif
            return false
        }
        return true
    }

    /// Look up the bearer for ``account``. Returns ``nil`` when the
    /// item is missing OR when the OS denies the read (locked device,
    /// ACL mismatch). Never raises.
    static func load(account: String = defaultAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the bearer (called by ``ConnectionStore.unpair``).
    static func delete(account: String = defaultAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-shot migration from the legacy UserDefaults key. Called by
    /// ``ConnectionStore.init`` on first launch of the new build so
    /// users who paired on v2026.5.38 don't get logged out.
    ///
    /// Returns the migrated bearer (or ``nil`` when there was nothing
    /// to migrate). After migration the UserDefaults entry is cleared
    /// so the unencrypted copy doesn't linger on disk.
    @discardableResult
    static func migrateFromUserDefaults(
        defaults: UserDefaults,
        legacyKey: String = "feral.phoneBearer",
        account: String = defaultAccount
    ) -> String? {
        guard load(account: account) == nil else {
            // Already on Keychain — clear the legacy copy if any
            // residual remains (operator restored from backup with
            // both copies present).
            defaults.removeObject(forKey: legacyKey)
            return nil
        }
        guard let legacy = defaults.string(forKey: legacyKey),
              !legacy.isEmpty else { return nil }
        let saved = save(legacy, account: account)
        if saved {
            defaults.removeObject(forKey: legacyKey)
            return legacy
        }
        return nil
    }
}
