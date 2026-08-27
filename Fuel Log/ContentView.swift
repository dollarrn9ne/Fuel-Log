// xcode: set sdk=iOS

//
//  ContentView.swift
//  Fuel Log
//
//  Created by Denis Yeremuk on 3/12/26.
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation
import MapKit
import PhotosUI
import StoreKit
import UniformTypeIdentifiers
import Combine
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications
@preconcurrency import Vision
import VisionKit
import AppIntents
import LocalAuthentication
import FuelLogShared

// MARK: - Root View
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
    @Query private var fillUps: [FillUp]
    @Query private var services: [ServiceRecord]
    @AppStorage("lastSelectedVehicleID") private var lastSelectedVehicleID: String = ""
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("hasSeenSplash") private var hasSeenSplash: Bool = false
    @AppStorage("lastSyncDate") private var lastSyncDate: Double = Date().timeIntervalSince1970
    @AppStorage("appLockEnabled") private var appLockEnabled: Bool = false
    @AppStorage("acknowledgedReportMonth") private var acknowledgedReportMonth: String = ""
    
    @State private var showingAddVehicle = false
    @StateObject private var quickActionManager = QuickActionManager.shared
    @StateObject private var menuCommands = MenuCommandBus.shared
    @State private var quickActionTarget: QuickActionManager.QuickAction?
    @State private var isUnlocked: Bool = false

    var unarchivedVehicles: [Vehicle] { vehicles.filter { !$0.isArchived } }
    var selectedVehicle: Vehicle? { unarchivedVehicles.first(where: { $0.id.uuidString == lastSelectedVehicleID }) ?? unarchivedVehicles.first }

    /// Steps to the next or previous vehicle, wrapping at either end so the
    /// shortcut keeps working rather than going dead on the last one.
    private func cycleVehicle(forward: Bool) {
        let list = unarchivedVehicles
        guard list.count > 1, let current = selectedVehicle,
              let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        let step = forward ? 1 : -1
        let next = (index + step + list.count) % list.count
        lastSelectedVehicleID = list[next].id.uuidString
    }

    var newReportMonth: Date? {
        let calendar = Calendar.current
        let today = Date()
        guard acknowledgedReportMonth != today.monthIdentifier else { return nil }
        if CommandLine.arguments.contains("-ForceMonthlyReport") {
            return calendar.date(byAdding: .month, value: -1, to: today)
        }
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: today),
              let monthStart = calendar.dateInterval(of: .month, for: previousMonth)?.start,
              let nextMonthStart = calendar.dateInterval(of: .month, for: today)?.start else { return nil }
        guard fillUps.contains(where: { $0.date >= monthStart && $0.date < nextMonthStart }) else { return nil }
        return previousMonth
    }

    private var widgetDataSignature: String {
        "\(vehicles.count)-\(fillUps.count)-\(services.count)-\(lastSelectedVehicleID)"
    }

    var body: some View {
        ZStack {
            // Main Dashboard Content
            Group {
                if (!appLockEnabled || isUnlocked) && hasSeenSplash {
                    if unarchivedVehicles.isEmpty {
                        EmptyGarageView(showingAdd: $showingAddVehicle)
                    } else if let vehicle = selectedVehicle {
                        MainDashboardView(vehicle: vehicle, allVehicles: unarchivedVehicles, onSelectVehicle: { newID in lastSelectedVehicleID = newID.uuidString }, newReportMonth: newReportMonth, onAcknowledgeReport: { acknowledgedReportMonth = Date().monthIdentifier })
                    }
                } else {
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                }
            }
            .transition(.opacity)
            .zIndex(1)

            // Splash Screen Layer
            if !hasSeenSplash {
                SplashScreenView(hasSeenSplash: $hasSeenSplash)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
            
            // Lock Screen Overlay
            if appLockEnabled && !isUnlocked {
                LockScreenView(isUnlocked: $isUnlocked)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: hasSeenSplash)
        .animation(.easeInOut, value: isUnlocked)
        .fontDesign(.rounded)
        .onAppear { 
            applyTheme(appTheme)
            injectMockDataIfNeeded()
            WidgetSnapshotUpdater.update(from: modelContext, lastSelectedVehicleID: lastSelectedVehicleID)
            handlePendingControlAction()
        }
        .onChange(of: appTheme) { _, newTheme in applyTheme(newTheme) }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                if appLockEnabled {
                    isUnlocked = false
                }
                try? modelContext.save()
                lastSyncDate = Date().timeIntervalSince1970
                WidgetSnapshotUpdater.update(from: modelContext, lastSelectedVehicleID: lastSelectedVehicleID)
            } else if newPhase == .active {
                WidgetSnapshotUpdater.update(from: modelContext, lastSelectedVehicleID: lastSelectedVehicleID)
                handlePendingControlAction()
            }
        }
        .onChange(of: widgetDataSignature) {
            WidgetSnapshotUpdater.update(from: modelContext, lastSelectedVehicleID: lastSelectedVehicleID)
        }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() } }
        .sheet(item: $quickActionTarget) { target in
            if let vehicle = selectedVehicle {
                if target == .addFuel { NavigationStack { AddFillUpView(vehicle: vehicle) } }
                else if target == .addService { NavigationStack { AddServiceView(vehicle: vehicle) } }
            }
        }
        // Vehicle switching lives here, since this is where the selection is held.
        .onChange(of: menuCommands.pending) { _, command in
            guard let command, command == .nextVehicle || command == .previousVehicle else { return }
            cycleVehicle(forward: command == .nextVehicle)
            menuCommands.consume(command)
        }
        .onChange(of: quickActionManager.action) { _, action in
            guard let action = action else { return }
            // The delay lets the UI settle when the app is launching from a Home
            // Screen quick action or a URL. A menu command arrives with the app
            // already on screen, where the same wait just feels unresponsive.
            let delay = quickActionManager.actionIsImmediate ? 0 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if action == .addVehicle { showingAddVehicle = true }
                else if selectedVehicle != nil { quickActionTarget = action }
                else { showingAddVehicle = true }
                quickActionManager.action = nil
                quickActionManager.actionIsImmediate = false
            }
        }
        .onOpenURL { url in
            guard url.scheme == "fuellog" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if url.host == "addFuel" { quickActionManager.action = .addFuel }
                else if url.host == "addService" { quickActionManager.action = .addService }
            }
        }
    }
    
    /// Picks up a quick action requested by the Log Fuel control (written to the
    /// App Group) and routes it through the existing quick-action presentation.
    private func handlePendingControlAction() {
        guard let defaults = UserDefaults(suiteName: FuelLogWidgetSnapshot.appGroupIdentifier),
              let action = defaults.string(forKey: FuelLogWidgetSnapshot.pendingActionKey) else { return }
        defaults.removeObject(forKey: FuelLogWidgetSnapshot.pendingActionKey)
        switch action {
        case "addFuel": quickActionManager.action = .addFuel
        case "addService": quickActionManager.action = .addService
        default: break
        }
    }

    private func applyTheme(_ theme: AppTheme) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for window in windowScene.windows {
            switch theme {
            case .system: window.overrideUserInterfaceStyle = .unspecified
            case .light: window.overrideUserInterfaceStyle = .light
            case .dark: window.overrideUserInterfaceStyle = .dark
            }
        }
    }
    
    // MARK: - Mock Data Injector (For UI Tests)
    private func injectMockDataIfNeeded() {
        guard CommandLine.arguments.contains("-UITestMockData") else { return }
        
        // Skip splash screen
        UserDefaults.standard.set(true, forKey: "hasSeenSplash")
        
        let descriptor = FetchDescriptor<Vehicle>()
        let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }
        
        let vehicle = Vehicle(name: "2024 Toyota RAV4", make: "Toyota", model: "RAV4", year: 2024)
        modelContext.insert(vehicle)
        
        let now = Date()
        let cal = Calendar.current
        
        let costco = GasLocation(name: "Costco Gas", latitude: 37.33233141, longitude: -122.0312186)
        let shell = GasLocation(name: "Shell", latitude: 37.4, longitude: -122.1)
        modelContext.insert(costco)
        modelContext.insert(shell)
        
        let f1 = FillUp(date: cal.date(byAdding: .day, value: -25, to: now)!, odometer: 15200, volume: 11.2, pricePerUnit: 4.35, isFullTank: true, notes: "", unit: .gallons, vehicle: vehicle, location: costco)
        let f2 = FillUp(date: cal.date(byAdding: .day, value: -14, to: now)!, odometer: 15550, volume: 10.8, pricePerUnit: 4.49, isFullTank: true, notes: "Road trip start", unit: .gallons, vehicle: vehicle, location: shell)
        let f3 = FillUp(date: cal.date(byAdding: .day, value: -2, to: now)!, odometer: 15910, volume: 12.1, pricePerUnit: 4.29, isFullTank: true, notes: "", unit: .gallons, vehicle: vehicle, location: costco)
        
        modelContext.insert(f1)
        modelContext.insert(f2)
        modelContext.insert(f3)
        vehicle.fillUps = [f1, f2, f3]
        
        let s1 = ServiceRecord(date: cal.date(byAdding: .day, value: -40, to: now)!, odometer: 14800, type: .oilChange, cost: 89.99, notes: "Synthetic oil change and tire rotation", vehicle: vehicle, location: GasLocation(name: "Toyota Dealership", latitude: 37.3, longitude: -122.0))
        modelContext.insert(s1)
        vehicle.services = [s1]
        
        let cat = TripCategory(name: "Vacation")
        modelContext.insert(cat)
        let t1 = Trip(name: "Weekend Getaway", startDate: cal.date(byAdding: .day, value: -14, to: now)!, endDate: cal.date(byAdding: .day, value: -12, to: now)!, startOdometer: 15550, endOdometer: 15800, category: cat, vehicle: vehicle)
        modelContext.insert(t1)
        vehicle.trips = [t1]
        
        try? modelContext.save()
        lastSelectedVehicleID = vehicle.id.uuidString
    }
}

