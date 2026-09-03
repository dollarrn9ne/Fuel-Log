// xcode: set sdk=iOS

//
//  AppIntents.swift
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

// MARK: - Vehicle Entity (for Siri / Shortcuts)

struct VehicleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle")
    static let defaultQuery = VehicleQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct VehicleQuery: EntityQuery {
    @MainActor
    private func openContext() throws -> ModelContext {
        try FuelLogContainer.makeContainer().get().mainContext
    }

    @MainActor
    func entities(for identifiers: [VehicleEntity.ID]) async throws -> [VehicleEntity] {
        let context = try openContext()
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        return vehicles
            .filter { !$0.isArchived && identifiers.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { VehicleEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [VehicleEntity] {
        let context = try openContext()
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        return vehicles
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { VehicleEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - App Intents

struct LogFuelIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Fuel"
    static let description = IntentDescription("Log a fuel fill-up for one of your vehicles.")

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity?

    @Parameter(title: "Volume")
    var volume: Double?

    @Parameter(title: "Price per Unit")
    var pricePerUnit: Double?

    @Parameter(title: "Odometer")
    var odometer: Double?

    @Parameter(title: "Location")
    var location: String?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "Full Tank", default: true)
    var isFullTank: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$volume) units of fuel at \(\.$pricePerUnit) per unit") {
            \.$vehicle
            \.$location
            \.$odometer
            \.$date
            \.$notes
            \.$isFullTank
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let volume = volume, volume > 0 else { throw IntentError.missingVolume }
        guard let pricePerUnit = pricePerUnit, pricePerUnit >= 0 else { throw IntentError.missingPrice }

        let container = try FuelLogContainer.makeContainer().get()
        let context = container.mainContext

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let unarchived = vehicles.filter { !$0.isArchived }

        let resolvedVehicle: Vehicle
        if let vehicleID = vehicle?.id, let match = unarchived.first(where: { $0.id == vehicleID }) {
            resolvedVehicle = match
        } else if let first = unarchived.first {
            resolvedVehicle = first
        } else {
            throw IntentError.noVehicle
        }

        let resolvedLocation = try resolveLocation(named: location, in: context)

        let fillUp = FillUp(date: date ?? Date(), odometer: odometer, volume: volume, pricePerUnit: pricePerUnit, isFullTank: isFullTank, notes: notes ?? "", unit: resolvedVehicle.fuelUnit, vehicle: resolvedVehicle, location: resolvedLocation)
        context.insert(fillUp)
        if resolvedVehicle.fillUps == nil { resolvedVehicle.fillUps = [] }
        resolvedVehicle.fillUps?.append(fillUp)

        try context.save()

        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: resolvedVehicle)
        }

        // Keep the widgets in sync after logging outside the app (Siri/Shortcuts).
        WidgetSnapshotUpdater.update(from: context, lastSelectedVehicleID: UserDefaults.standard.string(forKey: "lastSelectedVehicleID") ?? "")

        return .result(value: "Logged \(volume.formatted()) \(resolvedVehicle.fuelUnit.rawValue) for \(resolvedVehicle.name). Total cost: \((volume * pricePerUnit).formatted(.currency(code: resolvedVehicle.currencyRaw))).")
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case noVehicle
        case missingVolume
        case missingPrice
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noVehicle: return "No active vehicle found. Please add a vehicle first."
            case .missingVolume: return "Please provide the fuel volume."
            case .missingPrice: return "Please provide the price per unit."
            }
        }
    }
}

struct LogServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Service"

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity?

    @Parameter(title: "Service Type")
    var type: ServiceType

    @Parameter(title: "Cost")
    var cost: Double

    @Parameter(title: "Odometer")
    var odometer: Double

    @Parameter(title: "Location")
    var location: String?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Notes")
    var notes: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$type) service for \(\.$cost)") {
            \.$vehicle
            \.$location
            \.$odometer
            \.$date
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = try FuelLogContainer.makeContainer().get()
        let context = container.mainContext

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let unarchived = vehicles.filter { !$0.isArchived }

        let resolvedVehicle: Vehicle
        if let vehicleID = vehicle?.id, let match = unarchived.first(where: { $0.id == vehicleID }) {
            resolvedVehicle = match
        } else if let first = unarchived.first {
            resolvedVehicle = first
        } else {
            throw IntentError.noVehicle
        }

        let resolvedLocation = try resolveLocation(named: location, in: context)

        let record = ServiceRecord(date: date ?? Date(), odometer: odometer, type: type, cost: cost, notes: notes ?? "", vehicle: resolvedVehicle, location: resolvedLocation)
        context.insert(record)
        if resolvedVehicle.services == nil { resolvedVehicle.services = [] }
        resolvedVehicle.services?.append(record)

        try context.save()

        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: resolvedVehicle)
        }

        // Keep the widgets in sync after logging outside the app (Siri/Shortcuts).
        WidgetSnapshotUpdater.update(from: context, lastSelectedVehicleID: UserDefaults.standard.string(forKey: "lastSelectedVehicleID") ?? "")

        return .result(value: "Logged \(type.rawValue) for \(resolvedVehicle.name) at \(cost.formatted(.currency(code: resolvedVehicle.currencyRaw))).")
    }

    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case noVehicle
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noVehicle: return "No active vehicle found."
            }
        }
    }
}

// MARK: - Shared helpers

private func resolveLocation(named name: String?, in context: ModelContext) throws -> GasLocation? {
    guard let rawName = name, !rawName.isEmpty else { return nil }
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let locations = try context.fetch(FetchDescriptor<GasLocation>())
    if let existing = locations.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
        return existing
    }

    let newLocation = GasLocation(name: trimmed, latitude: 0, longitude: 0)
    context.insert(newLocation)
    return newLocation
}

struct FuelLogShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogFuelIntent(),
            phrases: [
                "Log fuel in \(.applicationName)",
                "Add a fill up to \(.applicationName)",
                "Log gas in \(.applicationName)",
                "Add a charge to \(.applicationName)"
            ],
            shortTitle: "Log Fuel",
            systemImageName: "fuelpump.fill"
        )
        AppShortcut(
            intent: LogServiceIntent(),
            phrases: [
                "Log service in \(.applicationName)",
                "Add maintenance to \(.applicationName)",
                "Log an oil change in \(.applicationName)"
            ],
            shortTitle: "Log Service",
            systemImageName: "wrench.and.screwdriver.fill"
        )
    }
}
