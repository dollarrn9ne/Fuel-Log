import Foundation
import Combine
import StoreKit

// MARK: - Support Tiers

/// A tip amount offered in the Support Developer menu. Each amount needs its own
/// App Store product, since in-app purchase prices are fixed per product.
enum SupportTier: String, CaseIterable, Identifiable {
    case ten = "com.motosung.fuellog.tip10"
    case twentyFive = "com.motosung.fuellog.tip25"
    case fifty = "com.motosung.fuellog.tip50"
    case oneHundred = "com.motosung.fuellog.tip100"

    var id: String { rawValue }

    /// Fallback label shown until StoreKit provides the localized price.
    var nominalPrice: String {
        switch self {
        case .ten: return "$10"
        case .twentyFive: return "$25"
        case .fifty: return "$50"
        case .oneHundred: return "$100"
        }
    }
}

@MainActor
final class StoreKitManager: ObservableObject {
    /// The original one-time support product. Retained so people who bought it
    /// before the tip tiers existed still show as supporters and can restore.
    static let legacySupportProductID = "com.motosung.fuellog.support"

    /// Tips are consumable, so they can't be restored through the App Store.
    /// Remember that the user has supported at least once in iCloud key-value
    /// storage, so the thank-you follows their Apple ID across devices and
    /// survives reinstalls. UserDefaults mirrors it for offline launches.
    private nonisolated static let hasSupportedKey = "hasSupportedDeveloper"

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var isPurchasing = false
    @Published private(set) var hasPurchasedSupport = false
    @Published var errorMessage: String?
    @Published var purchaseCompleted = false

    private var updatesTask: Task<Void, Never>?
    private var cloudObserver: NSObjectProtocol?

    init() {
        let cloud = NSUbiquitousKeyValueStore.default
        hasPurchasedSupport = cloud.bool(forKey: Self.hasSupportedKey)
            || UserDefaults.standard.bool(forKey: Self.hasSupportedKey)

        // Pick up a tip made on another device.
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            guard NSUbiquitousKeyValueStore.default.bool(forKey: Self.hasSupportedKey) else { return }
            MainActor.assumeIsolated { self?.markSupported() }
        }
        cloud.synchronize()

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
                if case .verified(let transaction) = result, transaction.productID == Self.legacySupportProductID {
                    markSupported()
                }
            }
        }
        Task { await loadProducts() }
    }

    deinit {
        updatesTask?.cancel()
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: SupportTier.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The price to show for a tier, preferring StoreKit's localized price.
    func displayPrice(for tier: SupportTier) -> String {
        products[tier.rawValue]?.displayPrice ?? tier.nominalPrice
    }

    func purchase(_ tier: SupportTier) async {
        if products[tier.rawValue] == nil { await loadProducts() }
        guard let product = products[tier.rawValue] else {
            errorMessage = "That support option isn't available right now. Please try again later."
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
                    markSupported()
                    purchaseCompleted = true
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

    private func handle(_ transaction: Transaction) async {
        let supportIDs = Set(SupportTier.allCases.map(\.rawValue) + [Self.legacySupportProductID])
        if supportIDs.contains(transaction.productID) {
            markSupported()
            purchaseCompleted = true
        }
        await transaction.finish()
    }

    private func markSupported() {
        hasPurchasedSupport = true
        UserDefaults.standard.set(true, forKey: Self.hasSupportedKey)
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.set(true, forKey: Self.hasSupportedKey)
        cloud.synchronize()
    }
}
