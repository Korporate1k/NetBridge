import Foundation

/// App-managed free trial, fully server-controlled: base duration
/// (`setTrialDuration`), an optional hard calendar ceiling that combines
/// with the duration rather than replacing it (`setAbsoluteCeiling`), a
/// global kill switch (`setForceEnded`), a new-install eligibility gate
/// (`setTrialEnabled`), and repeatable bonus-day promos (`applyBonus`) — no
/// StoreKit involved. The first-launch date and bonus record both live in
/// the Keychain (`KeychainStore`), not `UserDefaults` — Keychain items
/// survive a delete-and-reinstall on the same device, so reinstalling
/// doesn't grant a fresh trial the way `UserDefaults`-backed state would.
final class TrialManager: ObservableObject {
    private static let defaultTrialDurationHours: Double = 168 // 7 days
    private static let firstLaunchKey = "trial.firstLaunchDate"
    private static let bonusKey = "trial.bonus"

    @Published private(set) var isInTrial = false
    @Published private(set) var remainingSeconds: TimeInterval = 0

    /// Set by `RemoteConfigManager` from the remote config's
    /// `trialDurationHours` — recomputes every existing trial's countdown
    /// immediately, including ones already in progress.
    private var trialDurationHours = TrialManager.defaultTrialDurationHours
    /// An additional hard ceiling (e.g. "no trial extends past Jan 1,
    /// 2027") — combines with `trialDurationHours` via `min`, rather than
    /// replacing the per-user countdown.
    private var absoluteCeiling: Date?
    /// Global kill switch — when true, every trial (new or in progress)
    /// reads as over immediately, regardless of the date math.
    private var forceEnded = false
    /// Whether a *brand-new* install (no prior Keychain record this launch)
    /// is eligible for a trial at all. Existing installs that already have
    /// a persisted `firstLaunchDate` keep their countdown even if this
    /// later flips to false — it only gates new grants going forward.
    private var trialEnabledForNewInstalls = true
    private let isFreshInstall: Bool

    private let firstLaunchDate: Date

    private struct BonusRecord: Codable {
        var totalBonusDays: Int
        /// Every campaign ID ever applied, not just the most recent one.
        /// The remote config's raw-Gist CDN can transiently re-serve an
        /// older cached revision for one poll cycle right after an edit
        /// (observed directly: campaignID flipping 1→2→1→2 across
        /// consecutive 10s polls before settling) — guarding only against
        /// the *last* applied ID let that jitter double- and triple-grant
        /// the same bonus. Guarding against the full history closes that.
        var appliedCampaignIDs: Set<String>
    }
    private var bonus = BonusRecord(totalBonusDays: 0, appliedCampaignIDs: [])

    init() {
        if let data = KeychainStore.load(key: Self.firstLaunchKey),
           let stored = try? JSONDecoder().decode(Date.self, from: data) {
            firstLaunchDate = stored
            isFreshInstall = false
        } else {
            let now = Date()
            firstLaunchDate = now
            isFreshInstall = true
            if let data = try? JSONEncoder().encode(now) {
                KeychainStore.save(data, key: Self.firstLaunchKey)
            }
        }
        if let data = KeychainStore.load(key: Self.bonusKey),
           let stored = try? JSONDecoder().decode(BonusRecord.self, from: data) {
            bonus = stored
        }
        refresh()
    }

    /// Updates the base trial length (hours) and immediately recomputes
    /// status against it — a no-op for an invalid (<= 0) value.
    func setTrialDuration(hours: Double) {
        guard hours > 0 else { return }
        trialDurationHours = hours
        refresh()
    }

    /// Sets (or clears, with `nil`) the hard calendar ceiling.
    func setAbsoluteCeiling(_ date: Date?) {
        absoluteCeiling = date
        refresh()
    }

    /// Global kill switch — `true` ends every trial immediately.
    func setForceEnded(_ ended: Bool) {
        forceEnded = ended
        refresh()
    }

    /// Whether brand-new installs are currently eligible for a trial.
    /// Installs that already have a trial in progress are unaffected.
    func setTrialEnabled(_ enabled: Bool) {
        trialEnabledForNewInstalls = enabled
        refresh()
    }

    /// Grants a one-time bonus for `campaignID` — a no-op if this campaign
    /// was EVER already applied (not just most-recently), so re-fetching an
    /// unchanged remote config on every launch — or a transient stale read
    /// from the config CDN reverting to a previously-seen campaignID for
    /// one poll cycle — doesn't re-extend the trial indefinitely. A new,
    /// never-seen `campaignID` always applies, extending from wherever the
    /// user currently is: more days added mid-trial, or a fresh bonus
    /// window if their original trial already lapsed.
    func applyBonus(days: Int, campaignID: String) {
        guard !campaignID.isEmpty, !bonus.appliedCampaignIDs.contains(campaignID) else { return }
        bonus.totalBonusDays += days
        bonus.appliedCampaignIDs.insert(campaignID)
        if let data = try? JSONEncoder().encode(bonus) {
            KeychainStore.save(data, key: Self.bonusKey)
        }
        DebugLog.important("trial", "applied bonus +\(days)d from campaign \(campaignID), total bonus=\(bonus.totalBonusDays)d")
        refresh()
    }

    /// Re-evaluates trial status — cheap enough to call whenever the UI
    /// wants an up-to-date answer (e.g. on appear), since it's just a date
    /// comparison against the persisted first-launch date and bonus total.
    func refresh() {
        if forceEnded {
            isInTrial = false
            remainingSeconds = 0
            return
        }
        if isFreshInstall && !trialEnabledForNewInstalls {
            isInTrial = false
            remainingSeconds = 0
            return
        }
        let elapsedSeconds = Date().timeIntervalSince(firstLaunchDate)
        let totalSeconds = trialDurationHours * 3600 + Double(bonus.totalBonusDays) * 86400
        var remaining = totalSeconds - elapsedSeconds
        if let ceiling = absoluteCeiling {
            remaining = min(remaining, ceiling.timeIntervalSinceNow)
        }
        isInTrial = remaining > 0
        remainingSeconds = max(0, remaining)
    }

    /// A human-friendly countdown at whatever granularity makes sense —
    /// "3 days", "5 hours", or "12 minutes" — so a short (e.g. 24-hour)
    /// trial doesn't read as "0 days left" while hours still remain.
    var remainingDescription: String {
        if remainingSeconds >= 86400 {
            let days = Int((remainingSeconds / 86400).rounded(.up))
            return "\(days) day\(days == 1 ? "" : "s")"
        } else if remainingSeconds >= 3600 {
            let hours = Int((remainingSeconds / 3600).rounded(.up))
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let minutes = max(1, Int((remainingSeconds / 60).rounded(.up)))
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
    }
}
