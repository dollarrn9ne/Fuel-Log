import Foundation
import CloudKit
import SwiftUI

// MARK: - iCloud Sync Status Manager

@MainActor
public final class SyncManager: ObservableObject {
    public static let shared = SyncManager()

    public enum CloudStatus: Equatable {
        case checking
        case syncing
        case active
        case notSignedIn
        case restricted
        case unavailable
        case error(String)

        public var label: String {
            switch self {
            case .checking: return "Checking iCloud…"
            case .syncing: return "Syncing…"
            case .active: return "iCloud Sync is Active"
            case .notSignedIn: return "Not Signed In to iCloud"
            case .restricted: return "iCloud is Restricted"
            case .unavailable: return "iCloud Unavailable"
            case .error: return "Sync Error"
            }
        }

        public var detail: String {
            switch self {
            case .checking:
                return "Verifying your iCloud connection…"
            case .syncing:
                return "Your data is being synced right now."
            case .active:
                return "Your logs are securely and automatically synced across your Apple devices in the background."
            case .notSignedIn:
                return "Sign in to iCloud on this device to enable backup."
            case .restricted:
                return "iCloud access is restricted on this device (for example, by parental controls)."
            case .unavailable:
                return "iCloud is temporarily unavailable. Your data is safe on this device and will sync when iCloud returns."
            case .error(let message):
                return message
            }
        }

        public var icon: String {
            switch self {
            case .checking: return "icloud"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .active: return "icloud.fill"
            case .notSignedIn: return "icloud.slash.fill"
            case .restricted: return "lock.icloud.fill"
            case .unavailable: return "exclamationmark.icloud.fill"
            case .error: return "exclamationmark.icloud.fill"
            }
        }

        public var tintColor: Color {
            switch self {
            case .checking: return .secondary
            case .syncing: return .blue
            case .active: return .blue
            case .notSignedIn: return .orange
            case .restricted: return .orange
            case .unavailable: return .orange
            case .error: return .red
            }
        }

        public var isBusy: Bool {
            self == .checking || self == .syncing
        }
    }

    @Published public private(set) var status: CloudStatus = .checking
    @Published public private(set) var lastSuccessfulSync: Date?

    public static let lastSyncUserDefaultsKey = "lastSyncDate"

    private init() {}

    /// Checks the iCloud account status. Fast, lightweight.
    public func checkStatus() async {
        status = .checking
        let container = CKContainer.default()

        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                status = .active
            case .noAccount:
                status = .notSignedIn
            case .restricted:
                status = .restricted
            case .temporarilyUnavailable:
                status = .unavailable
            case .couldNotDetermine:
                status = .unavailable
            @unknown default:
                status = .unavailable
            }
        } catch {
            status = .error("Could not verify iCloud status: \(error.localizedDescription)")
        }
    }

    /// Performs a real end-to-end check: verifies the account AND that the
    /// CloudKit container is reachable, then records the last sync time.
    public func forceSync() async {
        status = .syncing
        let container = CKContainer.default()

        do {
            // fetchUserRecordID proves the container is registered and reachable.
            _ = try await container.userRecordID()
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                await checkStatus()
                return
            }
            status = .active
            let now = Date()
            lastSuccessfulSync = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastSyncUserDefaultsKey)
        } catch {
            status = .error("Sync failed: \(error.localizedDescription)")
        }
    }

    public func loadPersistedLastSync() {
        let value = UserDefaults.standard.double(forKey: Self.lastSyncUserDefaultsKey)
        if value > 0 {
            lastSuccessfulSync = Date(timeIntervalSince1970: value)
        }
    }
}
