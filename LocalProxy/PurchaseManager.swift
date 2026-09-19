import Foundation
import StoreKit

/// StoreKit2 wrapper for the single "remove the daily cap" non-consumable
/// unlock. Product ID must match whatever's created in App Store Connect
/// (or the local `Configuration.storekit` file used for Simulator testing).
@MainActor
final class PurchaseManager: ObservableObject {
    static let proProductID = "com.Korporate1k.LocalProxy.pro"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published var lastErrorMessage: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.proProductID])
            product = products.first
        } catch {
            DebugLog.important("iap", "product load failed \(ErrorDescription.describe(error))")
        }
    }

    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            await handle(result)
        }
    }

    func purchase() async {
        guard let product = product else { return }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            DebugLog.important("iap", "purchase failed \(ErrorDescription.describe(error))")
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastErrorMessage = error.localizedDescription
            DebugLog.important("iap", "restore failed \(ErrorDescription.describe(error))")
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
            isPro = true
        }
        await transaction.finish()
    }
}
