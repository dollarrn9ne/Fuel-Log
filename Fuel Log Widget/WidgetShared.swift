import WidgetKit
import SwiftUI
import AppIntents
import FuelLogShared

// MARK: - Snapshot Store

enum WidgetSnapshotStore {
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: FuelLogWidgetSnapshot.appGroupIdentifier)
    }

    static func load() -> FuelLogWidgetSnapshot? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: FuelLogWidgetSnapshot.storeKey),
              let snapshot = try? JSONDecoder().decode(FuelLogWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }
}

func selectedVehicle(from configuration: VehicleSelectionIntent, fallback: FuelLogWidgetSnapshot?) -> FuelLogWidgetVehicle? {
    if let id = configuration.vehicle?.id {
        return fallback?.vehicles.first { $0.id == id }
    }
    if let id = fallback?.lastSelectedVehicleID {
        return fallback?.vehicles.first { $0.id == id }
    }
    return fallback?.vehicles.first
}

// MARK: - Vehicle Selection (AppIntent configuration)

struct VehicleWidgetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle")
    static let defaultQuery = VehicleWidgetQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct VehicleWidgetQuery: EntityQuery {
    func entities(for identifiers: [VehicleWidgetEntity.ID]) async throws -> [VehicleWidgetEntity] {
        let vehicles = WidgetSnapshotStore.load()?.vehicles ?? []
        return vehicles.filter { identifiers.contains($0.id) }.map { VehicleWidgetEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [VehicleWidgetEntity] {
        let vehicles = WidgetSnapshotStore.load()?.vehicles ?? []
        return vehicles.map { VehicleWidgetEntity(id: $0.id, name: $0.name) }
    }
}

struct VehicleSelectionIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Vehicle"
    static let description = IntentDescription("Choose which vehicle to display.")

    @Parameter(title: "Vehicle")
    var vehicle: VehicleWidgetEntity?
}

// MARK: - Shared Formatting

enum WidgetFormatting {
    static func efficiencyValue(_ vehicle: FuelLogWidgetVehicle, efficiency: Double) -> String {
        let unit = EfficiencyUnit(rawValue: vehicle.efficiencyUnitRaw) ?? .mpgUS
        return String(format: unit == .l100km ? "%.1f" : "%.1f", efficiency)
    }

    static func efficiencyUnitLabel(_ vehicle: FuelLogWidgetVehicle) -> String {
        let unit = EfficiencyUnit(rawValue: vehicle.efficiencyUnitRaw) ?? .mpgUS
        switch unit {
        case .mpgUS: return "MPG"
        case .mpgUK: return "MPG (UK)"
        case .l100km: return "L/100 km"
        case .kmPerLitre: return "km/L"
        case .miPerKWh: return "mi/kWh"
        case .kmPerKWh: return "km/kWh"
        }
    }

    static func currency(_ value: Double, raw: String) -> String {
        let code = Currency(rawValue: raw)?.rawValue ?? "USD"
        return value.formatted(.currency(code: code))
    }

    static func remainingDistanceText(_ distance: Double, odometerUnitRaw: String) -> String {
        let unit = OdometerUnit(rawValue: odometerUnitRaw) ?? .miles
        let suffix = unit == .miles ? "mi" : "km"
        return "\(Int(distance.rounded())) \(suffix)"
    }

    static func distanceUnitSuffix(_ odometerUnitRaw: String) -> String {
        (OdometerUnit(rawValue: odometerUnitRaw) ?? .miles) == .miles ? "mi" : "km"
    }

    /// Whole number with thousands separators (odometer, etc.).
    static func wholeNumber(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    /// "Today" / "Yesterday" / "N days ago" from a date.
    static func daysAgoText(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0: return "Scheduled"
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }

    /// Fraction (0...1) of the way to the next service, for gauges.
    static func maintenanceProgress(_ vehicle: FuelLogWidgetVehicle) -> Double {
        guard vehicle.maintenanceInterval > 0, let remaining = vehicle.maintenanceRemainingDistance else { return 0 }
        let used = vehicle.maintenanceInterval - remaining
        return min(1, max(0, used / vehicle.maintenanceInterval))
    }
}

// MARK: - Widget Container Background

extension View {
    /// Applies an appropriate container background for the given family: a solid
    /// card on the Home Screen, the subtle accessory backdrop on Lock Screen /
    /// StandBy circular & rectangular, and none for inline.
    @ViewBuilder
    func fuelLogWidgetBackground(_ family: WidgetFamily) -> some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            self.containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            self.containerBackground(for: .widget) { Color.clear }
        default:
            self.containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
    }
}

// MARK: - Placeholder Vehicle

extension FuelLogWidgetVehicle {
    static var placeholder: FuelLogWidgetVehicle {
        FuelLogWidgetVehicle(
            id: UUID(),
            name: "2024 Toyota RAV4",
            make: "Toyota",
            model: "RAV4",
            odometerUnitRaw: OdometerUnit.miles.rawValue,
            fuelUnitRaw: FuelUnit.gallons.rawValue,
            efficiencyUnitRaw: EfficiencyUnit.mpgUS.rawValue,
            currencyRaw: Currency.usd.rawValue,
            isElectric: false,
            lastOdometer: 15910,
            averageEfficiency: 29.5,
            thisMonthSpend: 128.40,
            lastFillUpDate: Date().addingTimeInterval(-2 * 86400),
            isMaintenanceDue: false,
            maintenanceNextDate: Date().addingTimeInterval(35 * 86400),
            maintenanceRemainingDistance: 1240,
            maintenanceInterval: 5000,
            maintenanceIntervalMonths: 6,
            lastPricePerUnit: 4.29,
            thisYearFuelSpend: 1180.50,
            thisYearServiceSpend: 240.00,
            recentEfficiencyPoints: [27.4, 29.1, 28.2, 30.6, 31.0, 29.8, 32.4, 31.2]
        )
    }
}
