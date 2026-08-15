import SwiftData
import Foundation
import CloudKit

public enum FuelLogContainer {
    public static let sharedSchema = Schema([
        Vehicle.self,
        FillUp.self,
        ServiceRecord.self,
        GasLocation.self,
        Trip.self,
        TripCategory.self,
        ShareToken.self
    ])

    private static let wipeAttemptKey = "FuelLogContainer.didAttemptWipe"

    public static func makeContainer() -> Result<ModelContainer, Error> {
        let modelConfiguration = ModelConfiguration(schema: sharedSchema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: sharedSchema, configurations: [modelConfiguration])
            return .success(container)
        } catch {
            print("🚨 SwiftData failed to load. Error: \(error)")

            // Self-heal ONLY when it is safe to do so:
            // 1. Never wipe more than once per install, so a transient failure
            //    cannot trigger a destructive wipe on every launch.
            // 2. Only wipe if the user is signed into iCloud, so the data can be
            //    restored from the cloud. Otherwise keep the local store intact.
            guard !hasAttemptedWipe() else {
                print("⚠️ Self-heal skipped: a wipe was already attempted on this install.")
                return .failure(error)
            }

            guard isCloudKitAvailable() else {
                print("⚠️ Self-heal skipped: iCloud is unavailable, local data preserved.")
                return .failure(error)
            }

            markWipeAttempted()
            print("🔄 iCloud is healthy; wiping corrupted local database and retrying...")
            wipeLocalDatabases()

            do {
                print("🔄 Re-attempting container creation after wipe...")
                let container = try ModelContainer(for: sharedSchema, configurations: [modelConfiguration])
                return .success(container)
            } catch {
                print("❌ FAILED AGAIN. Error details: \(error)")
                return .failure(error)
            }
        }
    }

    private static func hasAttemptedWipe() -> Bool {
        UserDefaults.standard.bool(forKey: wipeAttemptKey)
    }

    private static func markWipeAttempted() {
        UserDefaults.standard.set(true, forKey: wipeAttemptKey)
    }

    private static func isCloudKitAvailable() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isAvailable = false

        CKContainer.default().accountStatus { status, error in
            isAvailable = (status == .available && error == nil)
            semaphore.signal()
        }

        // Only reached on the rare failure path; cap the wait so we never hang startup.
        _ = semaphore.wait(timeout: .now() + 3)
        return isAvailable
    }

    private static func wipeLocalDatabases() {
        // 1. Wipe the default directory database
        let url = ModelConfiguration(schema: sharedSchema, isStoredInMemoryOnly: false).url
        removeStoreFiles(at: url)

        // 2. Wipe the App Group database (just in case Xcode cached it here)
        let appGroupID = "group.com.motosung.fuellog"
        if let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            removeStoreFiles(at: sharedURL.appendingPathComponent("FuelLog.sqlite"))
        }
    }

    private static func removeStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("sqlite-shm"))
    }
}
