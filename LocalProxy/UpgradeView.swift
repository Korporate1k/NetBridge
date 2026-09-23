import SwiftUI
import StoreKit

/// The NetBridge Pro paywall: where the user stands today, what Pro gives, a monthly or lifetime
/// plan, and the subscription terms App Review requires (price, period, auto-renewal, Terms/Privacy).
struct UpgradeView: View {
    @ObservedObject var purchases: PurchaseManager
    @ObservedObject var trial: TrialManager
    var usedTodayBytes: UInt64 = 0
    var dailyLimitBytes: UInt64 = DailyUsageTracker.defaultDailyLimitBytes

    private enum Plan { case monthly, lifetime }

    @Environment(\.dismiss) private var dismiss
    @State private var plan: Plan = .monthly
    @State private var isWorking = false
    @State private var note: String?
    @State private var justUnlocked = false
    @State private var errorMessage: String?
    @State private var showManageSubscription = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if purchases.proSource == .lifetime || justUnlocked {
                        unlockedCard
                    } else {
                        if purchases.proSource == .subscription {
                            subscriptionCard
                        } else {
                            statusCard
                        }
                        benefits
                        planPicker
                        buyButton
                        if let note {
                            Text(note)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        legalFooter
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .manageSubscriptionsSheet(isPresented: $showManageSubscription)
            .onAppear {
                // Someone already on the monthly plan is here to look at lifetime.
                if purchases.proSource == .subscription { plan = .lifetime }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.accentColor)
            Text("NetBridge Pro")
                .font(.title2.weight(.bold))
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if trial.isInTrial {
                Label("Free trial: \(trial.remainingDescription) left", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("Today: \(DailyUsageTracker.formatDecimalGB(usedTodayBytes)) of \(DailyUsageTracker.formatDecimalGB(dailyLimitBytes)) used")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: min(Double(usedTodayBytes) / Double(max(dailyLimitBytes, 1)), 1))
                    .tint(usedTodayBytes >= dailyLimitBytes ? .red : .accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You're on NetBridge Pro Monthly", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.green)
            if let expires = purchases.subscriptionExpires {
                Text("\(purchases.willAutoRenew == false ? "Ends" : "Renews") \(expires.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button("Manage Subscription") { showManageSubscription = true }
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private var unlockedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text(purchases.proSource == .lifetime ? "Pro unlocked for life" : "Pro unlocked")
                .font(.headline)
            Text("No daily limit on this device or any iPhone or iPad signed in with the same Apple ID.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard()
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefitRow("infinity", "No daily limit", "The free tier relays up to \(DailyUsageTracker.formatDecimalGB(dailyLimitBytes)) a day.")
            benefitRow("iphone.and.arrow.forward", "On all your iPhones and iPads", "Restore with the same Apple ID.")
            benefitRow("checkmark.circle", "Your choice of plan", "Monthly, cancel anytime — or pay once for life.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefitRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            if purchases.proSource != .subscription {
                planCard(.monthly, title: "Monthly",
                         price: purchases.monthly.map { "\($0.displayPrice) / month" } ?? "—",
                         detail: "Renews monthly. Cancel anytime.")
            }
            planCard(.lifetime, title: "Lifetime",
                     price: purchases.lifetime?.displayPrice ?? "—",
                     detail: "One-time purchase. No renewals.")
        }
    }

    private func planCard(_ option: Plan, title: String, price: String, detail: String) -> some View {
        let selected = plan == option
        return Button { plan = option } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundColor(.primary)
                    Text(detail).font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
                Text(price)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedProduct: Product? {
        plan == .monthly ? purchases.monthly : purchases.lifetime
    }

    @ViewBuilder
    private var buyButton: some View {
        if purchases.productLoadFailed {
            Button {
                Task { await purchases.loadProducts() }
            } label: {
                Text("Couldn't load prices — Try Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
        } else {
            Button {
                guard let product = selectedProduct else { return }
                Task { await buy(product) }
            } label: {
                Group {
                    if isWorking {
                        ProgressView()
                    } else if let product = selectedProduct {
                        Text(plan == .monthly ? "Subscribe — \(product.displayPrice)/month" : "Buy Lifetime — \(product.displayPrice)")
                    } else {
                        Text("Loading…")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            .disabled(selectedProduct == nil || isWorking)
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 10) {
            if plan == .monthly, let monthly = purchases.monthly {
                Text("Payment is charged to your Apple ID when you confirm. NetBridge Pro Monthly renews automatically at \(monthly.displayPrice) per month unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple ID settings.")
            } else if plan == .lifetime, purchases.proSource == .subscription {
                Text("Buying Lifetime doesn't cancel your monthly plan. After buying, tap Manage Subscription and cancel it so you're not charged again.")
            }
            HStack(spacing: 16) {
                Link("Terms of Use", destination: PurchaseManager.termsURL)
                if let privacy = PurchaseManager.privacyURL {
                    Link("Privacy Policy", destination: privacy)
                }
                Button("Restore Purchases") { Task { await restore() } }
                    .disabled(isWorking)
            }
            .font(.footnote.weight(.semibold))
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: Actions

    private func buy(_ product: Product) async {
        isWorking = true
        note = nil
        let outcome = await purchases.purchase(product)
        isWorking = false
        switch outcome {
        case .purchased:
            unlocked()
        case .pending:
            note = "Waiting for approval. Pro unlocks automatically once the purchase is approved."
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    private func restore() async {
        isWorking = true
        note = nil
        let outcome = await purchases.restore()
        isWorking = false
        switch outcome {
        case .restored:
            unlocked()
        case .nothingToRestore:
            note = "No previous purchase or active subscription found for this Apple ID."
        case .failed(let message):
            errorMessage = message
        }
    }

    private func unlocked() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        justUnlocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
    }
}
