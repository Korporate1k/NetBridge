import Foundation
import StoreKit

/// StoreKit 2 wrapper for NetBridge Pro, which removes the daily cap. Two ways to get it:
/// a monthly auto-renewable subscription, or a lifetime non-consumable. Product IDs must
/// match App Store Connect (or the local `Configuration.storekit` used for Simulator testing).
/// iOS only — the Mac client has no paywall.
@MainActor
final class PurchaseManager: ObservableObject {
    /// The original "remove the daily cap" unlock, kept as the lifetime product so earlier buyers stay Pro.
    static let lifetimeProductID = "com.Korporate1k.LocalProxy.pro"
    static let monthlyProductID = "com.Korporate1k.LocalProxy.pro.monthly"

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Set once the privacy policy (docs/privacy.html) is published; the paywall hides the link while nil.
    static let privacyURL: URL? = nil

    enum ProSource: String, Codable { case lifetime, subscription }

    enum PurchaseOutcome { case purchased, pending, cancelled, failed(String) }
    enum RestoreOutcome { case restored, nothingToRestore, failed(String) }

    @Published private(set) var isPro: Bool
    @Published private(set) var proSource: ProSource?
    /// End of the current subscription period, when Pro comes from the monthly plan.
    @Published private(set) var subscriptionExpires: Date?
    /// Whether the monthly plan will renew at `subscriptionExpires` (false once cancelled).
    @Published private(set) var willAutoRenew: Bool?
    @Published private(set) var monthly: Product?
    @Published private(set) var lifetime: Product?
    @Published private(set) var productLoadFailed = false

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    // Last known Pro state, so a paying user isn't treated as free (and capped) during the moment after
    // launch before StoreKit answers. StoreKit stays the source of truth and overwrites it on every refresh.
    private struct Cache: Codable {
        var source: ProSource
        var expires: Date?
    }
    private static let cacheKey = "iap.proCache"

    init() {
        let cache = UserDefaults.standard.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        let cachedValid = cache.map { $0.source == .lifetime || ($0.expires ?? .distantPast) > Date() } ?? false
        isPro = cachedValid
        proSource = cachedValid ? cache?.source : nil
        subscriptionExpires = cachedValid ? cache?.expires : nil

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refresh()
        }
    }

    deinit {
        updatesTask?.cancel()
        expiryTask?.cancel()
    }

    func loadProducts() async {
        productLoadFailed = false
        do {
            let products = try await Product.products(for: [Self.monthlyProductID, Self.lifetimeProductID])
            monthly = products.first { $0.id == Self.monthlyProductID }
            lifetime = products.first { $0.id == Self.lifetimeProductID }
            productLoadFailed = monthly == nil && lifetime == nil
        } catch {
            productLoadFailed = true
            DebugLog.important("iap", "product load failed \(ErrorDescription.describe(error))")
        }
    }

    /// Recomputes Pro from the current entitlements — true *or* false, so refunds, revocations and
    /// lapsed subscriptions take Pro away. Called at launch, on every transaction update and when the
    /// app returns to the foreground (a subscription can expire with no transaction update at all).
    func refresh() async {
        var source: ProSource?
        var expires: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Self.lifetimeProductID:
                source = .lifetime
            case Self.monthlyProductID where (transaction.expirationDate ?? .distantFuture) > Date():
                if source == nil { source = .subscription }
                expires = max(expires ?? .distantPast, transaction.expirationDate ?? .distantFuture)
            default:
                break
            }
        }
        if source == .lifetime { expires = nil }
        apply(source: source, expires: expires)
        willAutoRenew = source == .subscription ? await autoRenewStatus() : nil
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    return .failed("The App Store couldn't verify this purchase.")
                }
                await transaction.finish()
                await refresh()
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            DebugLog.important("iap", "purchase failed \(ErrorDescription.describe(error))")
            return .failed(error.localizedDescription)
        }
    }

    func restore() async -> RestoreOutcome {
        do {
            try await AppStore.sync()
            await refresh()
            return isPro ? .restored : .nothingToRestore
        } catch {
            DebugLog.important("iap", "restore failed \(ErrorDescription.describe(error))")
            return .failed(error.localizedDescription)
        }
    }

    private func apply(source: ProSource?, expires: Date?) {
        isPro = source != nil
        proSource = source
        subscriptionExpires = source == .subscription ? expires : nil
        if let source {
            let data = try? JSONEncoder().encode(Cache(source: source, expires: subscriptionExpires))
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
        scheduleExpiryCheck()
    }

    /// While the app stays open past the end of a subscription period, recheck then — a renewal arrives
    /// through `Transaction.updates`, but a lapse doesn't arrive at all.
    private func scheduleExpiryCheck() {
        expiryTask?.cancel()
        guard let expires = subscriptionExpires else { return }
        let delay = max(1, expires.timeIntervalSinceNow + 5)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func autoRenewStatus() async -> Bool? {
        guard let statuses = try? await monthly?.subscription?.status else { return nil }
        for status in statuses {
            if case .verified(let info) = status.renewalInfo, info.currentProductID == Self.monthlyProductID {
                return info.willAutoRenew
            }
        }
        return nil
    }
}
