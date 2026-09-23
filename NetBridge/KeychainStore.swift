import Foundation
import Security

/// A tiny Keychain wrapper for the handful of values that need to survive
/// a delete-and-reinstall — unlike `UserDefaults` or files in Application
/// Support (both wiped when the app is deleted), Keychain items persist on
/// the device across reinstalls. Used by `TrialManager` (first-launch date)
/// and `DailyUsageTracker` (today's usage) specifically to close the
/// reinstall-to-reset loophole on the free tier.
///
/// `.afterFirstUnlockThisDeviceOnly` accessibility, no `kSecAttrSynchronizable`:
/// local to this device only, not included in iCloud Keychain sync or
/// restored onto a different device from a backup — this is about surviving
/// a reinstall on the *same* device, not tracking a person across devices.
enum KeychainStore {
    private static let service = "com.Korporate1k.LocalProxy.persistence"

    /// `accessGroup`, when non-nil, shares the item with another target
    /// signed with the same team via `keychain-access-groups` (used by the
    /// Client feature to share the SOCKS5 password with the
    /// `NetBridgeTunnel` extension). Note: the entitlement plist spells
    /// this as `$(AppIdentifierPrefix)com.Korporate1k.LocalProxy.shared`, but
    /// that build-variable syntax only resolves at codesigning time — at
    /// runtime the resolved form is `<TeamID>.com.Korporate1k.LocalProxy.shared`.
    /// This environment has no Team ID configured at all, so call sites
    /// pass the literal `"com.Korporate1k.LocalProxy.shared"` for now.
    static func save(_ data: Data, key: String, accessGroup: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(key: String, accessGroup: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
