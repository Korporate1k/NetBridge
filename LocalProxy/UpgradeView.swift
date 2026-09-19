import SwiftUI
import StoreKit

struct UpgradeView: View {
    @ObservedObject var purchases: PurchaseManager
    var dailyLimitBytes: UInt64 = DailyUsageTracker.defaultDailyLimitBytes
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var showError = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)

                Text("NetBridge Pro")
                    .font(.title2.weight(.bold))

                if purchases.isPro {
                    Label("You've already unlocked Pro — the daily cap doesn't apply.", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                } else {
                    Text("The free tier relays up to \(DailyUsageTracker.formatDecimalGB(dailyLimitBytes)) per day. Pro removes the daily cap, forever, with a single one-time purchase.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Task {
                            isPurchasing = true
                            await purchases.purchase()
                            isPurchasing = false
                            if purchases.lastErrorMessage != nil { showError = true }
                        }
                    } label: {
                        HStack {
                            Text(purchases.product?.displayPrice ?? "…")
                            Text("Remove Daily Cap")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                    .controlSize(.large)
                    .disabled(purchases.product == nil || isPurchasing)

                    Button("Restore Purchases") {
                        Task {
                            await purchases.restore()
                            if purchases.lastErrorMessage != nil { showError = true }
                        }
                    }
                    .font(.footnote)
                }
            }
            .padding(24)
            .glassCard(cornerRadius: 24)
            .padding()
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Something went wrong", isPresented: $showError, presenting: purchases.lastErrorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }
}
