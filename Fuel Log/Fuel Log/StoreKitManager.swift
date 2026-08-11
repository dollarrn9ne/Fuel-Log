import Foundation
import Combine
import StoreKit

@MainActor
final class StoreKitManager: ObservableObject {
    static let supportProductID = "com.motosung.fuellog.support"

    @Published private(set) var supportProduct: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var hasPurchasedSupport = false
    @Published var errorMessage: String?
    @Published var purchaseCompleted = false

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                switch result {
                case .verified(let transaction):
                    await self?.handle(transaction)
                case .unverified(_, _):
                    break
                }
            }
        }
        Task {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.productID == Self.supportProductID {
                    hasPurchasedSupport = true
                }
            }
        }
        Task { await loadProducts() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            supportProduct = try await Product.products(for: [Self.supportProductID]).first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase() async {
        if supportProduct == nil { await loadProducts() }
        guard let product = supportProduct else {
            errorMessage = "The Support Developer purchase isn't available right now. Please try again later."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    purchaseCompleted = true
                    hasPurchasedSupport = true
                }
            case .pending:
                errorMessage = "Your purchase is pending approval. You'll be notified when it completes."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ transaction: Transaction) async {
        if transaction.productID == Self.supportProductID {
            purchaseCompleted = true
            hasPurchasedSupport = true
        }
        await transaction.finish()
    }
}
