//
//  Fuel_LogApp.swift
//  Fuel Log
//
//  Created by Denis Yeremuk on 3/12/26.
//

import SwiftUI
import SwiftData
import Combine
import CloudKit
@preconcurrency import UserNotifications
import FuelLogShared

// MARK: - Quick Action Handling
@MainActor
class QuickActionManager: ObservableObject {
    static let shared = QuickActionManager()
    @Published var action: QuickAction? = nil
    
    enum QuickAction: String, Identifiable {
        case addFuel = "com.motosung.fuellog.addFuel"
        case addService = "com.motosung.fuellog.addService"
        case addVehicle = "com.motosung.fuellog.addVehicle"
        
        var id: String { rawValue }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        let fuelIcon = UIApplicationShortcutIcon(systemImageName: "fuelpump.fill")
        let serviceIcon = UIApplicationShortcutIcon(systemImageName: "wrench.and.screwdriver.fill")
        let vehicleIcon = UIApplicationShortcutIcon(systemImageName: "car.fill")
        
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: QuickActionManager.QuickAction.addFuel.rawValue, localizedTitle: "Add New Fuel Log", localizedSubtitle: nil, icon: fuelIcon, userInfo: nil),
            UIApplicationShortcutItem(type: QuickActionManager.QuickAction.addService.rawValue, localizedTitle: "Add New Service Log", localizedSubtitle: nil, icon: serviceIcon, userInfo: nil),
            UIApplicationShortcutItem(type: QuickActionManager.QuickAction.addVehicle.rawValue, localizedTitle: "Add New Vehicle", localizedSubtitle: nil, icon: vehicleIcon, userInfo: nil)
        ]
        // Enable silent CloudKit pushes so shared fill-up submissions import in
        // the background (see SharedLoggingImporter).
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await SharedLoggingImporter.shared.importNow()
        return .newData
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            QuickActionManager.shared.action = QuickActionManager.QuickAction(rawValue: shortcutItem.type)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        QuickActionManager.shared.action = QuickActionManager.QuickAction(rawValue: shortcutItem.type)
        completionHandler(true)
    }
}

// MARK: - Shared Logging Importer
//
// Owner side of the one-way relay: fetches FuelSubmission records that borrowers
// wrote to the public database for the owner's active share tokens, imports them
// as fill-ups, dedupes by clientSubmissionID, and cleans up. Also registers the
// silent-push subscriptions that trigger near-instant background imports.
@MainActor
final class SharedLoggingImporter {
    static let shared = SharedLoggingImporter()
    private init() {}

    private var container: ModelContainer?
    private let database = CKContainer.default().publicCloudDatabase
    private let importedIDsKey = "importedSubmissionIDs"

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: FuelLogWidgetSnapshot.appGroupIdentifier)
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: Push subscriptions (Phase 3)

    /// Subscribes to record creations for a token so the owner gets a silent
    /// push and imports in the background the moment a borrower submits.
    func registerSubscription(for token: UUID) {
        let predicate = NSPredicate(format: "%K == %@", SharedLogging.Field.token, token.uuidString)
        let subscription = CKQuerySubscription(
            recordType: SharedLogging.recordType,
            predicate: predicate,
            subscriptionID: "share-\(token.uuidString)",
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true // silent background push
        subscription.notificationInfo = info
        let db = database
        Task { try? await db.save(subscription) }
    }

    func removeSubscription(for token: UUID) {
        let db = database
        Task { try? await db.deleteSubscription(withID: "share-\(token.uuidString)") }
    }

    // MARK: Import

    /// Fetches and imports any pending submissions for the owner's active tokens.
    func importNow() async {
        guard let container else { return }
        let context = ModelContext(container)

        let activeTokens = ((try? context.fetch(FetchDescriptor<ShareToken>())) ?? []).filter { $0.isActive }
        guard !activeTokens.isEmpty else { return }

        // Query per token (CloudKit predicate `IN` support is limited).
        var fetched: [(CKRecord.ID, CKRecord)] = []
        for shareToken in activeTokens {
            let predicate = NSPredicate(format: "%K == %@", SharedLogging.Field.token, shareToken.token.uuidString)
            let query = CKQuery(recordType: SharedLogging.recordType, predicate: predicate)
            guard let response = try? await database.records(matching: query) else { continue }
            for (recordID, result) in response.matchResults {
                if case .success(let record) = result { fetched.append((recordID, record)) }
            }
        }
        guard !fetched.isEmpty else { return }

        let vehicles = (try? context.fetch(FetchDescriptor<Vehicle>())) ?? []
        var vehiclesByID: [UUID: Vehicle] = [:]
        for vehicle in vehicles { vehiclesByID[vehicle.id] = vehicle }

        var imported = Set(sharedDefaults?.stringArray(forKey: importedIDsKey) ?? [])
        var recordsToDelete: [CKRecord.ID] = []
        var importedVehicleNames: [String] = []

        for (recordID, record) in fetched {
            guard let payload = FuelSubmissionPayload(record: record) else { continue }

            if imported.contains(payload.clientSubmissionID) {
                recordsToDelete.append(recordID) // already imported; just clean up
                continue
            }
            guard let vehicle = vehiclesByID[payload.vehicleID] else {
                // Vehicle no longer exists locally; drop the submission.
                imported.insert(payload.clientSubmissionID)
                recordsToDelete.append(recordID)
                continue
            }

            var location: GasLocation? = nil
            let station = payload.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !station.isEmpty {
                let loc = GasLocation(name: station, latitude: 0, longitude: 0)
                context.insert(loc)
                location = loc
            }

            let fill = FillUp(
                date: payload.date,
                odometer: payload.odometer,
                volume: payload.volume,
                pricePerUnit: payload.pricePerUnit,
                isFullTank: payload.isFullTank,
                notes: payload.notes,
                unit: FuelUnit(rawValue: payload.unitRaw) ?? .gallons,
                vehicle: vehicle,
                location: location
            )
            context.insert(fill)
            if vehicle.fillUps == nil { vehicle.fillUps = [] }
            vehicle.fillUps?.append(fill)

            imported.insert(payload.clientSubmissionID)
            recordsToDelete.append(recordID)
            importedVehicleNames.append(vehicle.name)
        }

        if !importedVehicleNames.isEmpty {
            try? context.save()
            sharedDefaults?.set(Array(imported), forKey: importedIDsKey)
            WidgetSnapshotUpdater.update(from: context, lastSelectedVehicleID: UserDefaults.standard.string(forKey: "lastSelectedVehicleID") ?? "")
            await postImportNotification(vehicleNames: importedVehicleNames)
        }

        // Best-effort cleanup. The owner may lack delete permission on records a
        // borrower created (public DB creator-only), which is fine: the dedupe
        // set prevents any re-import.
        if !recordsToDelete.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: recordsToDelete)
        }
    }

    private func postImportNotification(vehicleNames: [String]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        let unique = Array(Set(vehicleNames))
        if unique.count == 1, let name = unique.first {
            content.title = "New Fill-Up Logged"
            content.body = "A shared fill-up was added to \(name)."
        } else {
            content.title = "New Fill-Ups Logged"
            content.body = "\(vehicleNames.count) shared fill-ups were imported."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sharedImport-\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }
}

// MARK: - App Entry Point
@main
struct Fuel_LogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var modelContainerResult: Result<ModelContainer, Error> = FuelLogContainer.makeContainer()

    var body: some Scene {
        WindowGroup {
            switch modelContainerResult {
            case .success(let container):
                ContentView()
                    .modelContainer(container)
                    .task {
                        SharedLoggingImporter.shared.configure(container: container)
                        await SharedLoggingImporter.shared.importNow()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task { await SharedLoggingImporter.shared.importNow() }
                        }
                    }
            case .failure(let error):
                // Show a graceful error state to the user rather than crashing
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.red)
                    Text("Database Error")
                        .font(.title)
                        .bold()
                    Text("The app could not load your saved data. This might be due to a schema mismatch or CloudKit error.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    ScrollView {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                    }
                }
                .padding()
            }
        }
        // Menu bar commands, for the hardware-keyboard case on iPad. Routed
        // through QuickActionManager, the same bus the Home Screen quick actions
        // already use, so ContentView needs no changes to handle them.
        .commands {
            CommandGroup(after: .newItem) {
                Button("Log Fuel…") { QuickActionManager.shared.action = .addFuel }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
