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
    /// Outcome of a Keychain read. "Not found" and "the read failed" are different answers: treating a failed read
    /// (locked keychain, missing entitlement, interaction not allowed) as "no value" is how a stored password gets
    /// overwritten with an empty one.
    enum LoadResult {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    /// Writes `data`, updating the existing item in place (`SecItemUpdate`) and adding it only when there is none
    /// (`errSecItemNotFound`). The old delete-then-add lost the stored value whenever the add then failed.
    /// Returns the final OSStatus (`errSecSuccess` on success); failures are logged.
    @discardableResult
    static func save(_ data: Data, key: String, accessGroup: String? = nil) -> OSStatus {
        let query = baseQuery(key: key, accessGroup: accessGroup)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            DebugLog.important("keychain", "save \(key) failed OSStatus=\(status)")
        }
        return status
    }

    static func loadResult(key: String, accessGroup: String? = nil) -> LoadResult {
        var query = baseQuery(key: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                DebugLog.important("keychain", "load \(key) returned no data")
                return .failed(errSecDecode)
            }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            DebugLog.important("keychain", "load \(key) failed OSStatus=\(status)")
            return .failed(status)
        }
    }

    /// The stored value, or `nil` when there is none OR the read failed. Callers that would write back what they
    /// read must use `loadResult` instead, so a failed read is not mistaken for "empty".
    static func load(key: String, accessGroup: String? = nil) -> Data? {
        if case .found(let data) = loadResult(key: key, accessGroup: accessGroup) { return data }
        return nil
    }

    private static func baseQuery(key: String, accessGroup: String?) -> [String: Any] {
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
        return query
    }
}
