//
//  Fuel_LogApp.swift
//  Fuel Log
//
//  Created by Denis Yeremuk on 3/12/26.
//

import SwiftUI
import SwiftData
import Combine

// MARK: - Quick Action Handling
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
        return true
    }
    
    // Captures the shortcut if the app is cold-launching
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
    // Captures the shortcut if the app is already running in the background
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        QuickActionManager.shared.action = QuickActionManager.QuickAction(rawValue: shortcutItem.type)
        completionHandler(true)
    }
}

// MARK: - App Entry Point
@main
struct Fuel_LogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Vehicle.self,
            FillUp.self,
            ServiceRecord.self,
            GasLocation.self,
            Trip.self,
            TripCategory.self
        ])
        
        let appGroupID = "group.com.motosung.fuellog"
        
        // Attempt to store the database in the shared App Group so the Widget can read it
        if let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let storeURL = sharedURL.appendingPathComponent("FuelLog.sqlite")
            let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create shared ModelContainer: \(error)")
            }
        }
        
        // Fallback for previews or if App Group is missing
        let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [fallbackConfig])
        } catch {
            fatalError("Could not create fallback ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
