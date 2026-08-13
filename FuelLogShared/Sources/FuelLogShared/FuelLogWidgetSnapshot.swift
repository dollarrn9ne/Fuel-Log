import Foundation

// MARK: - Widget Snapshot

/// A lightweight, codable snapshot of vehicle data that the containing app writes
/// to a shared App Group UserDefaults container so widgets can render quickly
/// without touching the CloudKit-backed SwiftData store.
public struct FuelLogWidgetSnapshot: Codable, Sendable {
    public var lastSelectedVehicleID: UUID?
    public var vehicles: [FuelLogWidgetVehicle]

    public init(lastSelectedVehicleID: UUID?, vehicles: [FuelLogWidgetVehicle]) {
        self.lastSelectedVehicleID = lastSelectedVehicleID
        self.vehicles = vehicles
    }

    public static let appGroupIdentifier = "group.com.motosung.fuellog"
    public static let storeKey = "fuelLogWidgetSnapshot"
    /// App Group key a Control writes to request the app open a quick action
    /// (e.g. "addFuel") the next time it becomes active.
    public static let pendingActionKey = "pendingControlAction"
}

public struct FuelLogWidgetVehicle: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var make: String
    public var model: String
    public var odometerUnitRaw: String
    public var fuelUnitRaw: String
    public var efficiencyUnitRaw: String
    public var currencyRaw: String
    public var isElectric: Bool
    public var lastOdometer: Double?
    public var averageEfficiency: Double?
    public var thisMonthSpend: Double
    public var lastFillUpDate: Date?
    public var isMaintenanceDue: Bool
    public var maintenanceNextDate: Date?
    public var maintenanceRemainingDistance: Double?
    public var maintenanceInterval: Double
    public var maintenanceIntervalMonths: Double
    public var lastPricePerUnit: Double?
    public var thisYearFuelSpend: Double
    public var thisYearServiceSpend: Double
    /// Recent per-segment efficiency values (oldest→newest) for a sparkline.
    public var recentEfficiencyPoints: [Double]

    public init(
        id: UUID,
        name: String,
        make: String,
        model: String,
        odometerUnitRaw: String,
        fuelUnitRaw: String,
        efficiencyUnitRaw: String,
        currencyRaw: String,
        isElectric: Bool,
        lastOdometer: Double?,
        averageEfficiency: Double?,
        thisMonthSpend: Double,
        lastFillUpDate: Date?,
        isMaintenanceDue: Bool,
        maintenanceNextDate: Date?,
        maintenanceRemainingDistance: Double?,
        maintenanceInterval: Double,
        maintenanceIntervalMonths: Double,
        lastPricePerUnit: Double? = nil,
        thisYearFuelSpend: Double = 0,
        thisYearServiceSpend: Double = 0,
        recentEfficiencyPoints: [Double] = []
    ) {
        self.id = id
        self.name = name
        self.make = make
        self.model = model
        self.odometerUnitRaw = odometerUnitRaw
        self.fuelUnitRaw = fuelUnitRaw
        self.efficiencyUnitRaw = efficiencyUnitRaw
        self.currencyRaw = currencyRaw
        self.isElectric = isElectric
        self.lastOdometer = lastOdometer
        self.averageEfficiency = averageEfficiency
        self.thisMonthSpend = thisMonthSpend
        self.lastFillUpDate = lastFillUpDate
        self.isMaintenanceDue = isMaintenanceDue
        self.maintenanceNextDate = maintenanceNextDate
        self.maintenanceRemainingDistance = maintenanceRemainingDistance
        self.maintenanceInterval = maintenanceInterval
        self.maintenanceIntervalMonths = maintenanceIntervalMonths
        self.lastPricePerUnit = lastPricePerUnit
        self.thisYearFuelSpend = thisYearFuelSpend
        self.thisYearServiceSpend = thisYearServiceSpend
        self.recentEfficiencyPoints = recentEfficiencyPoints
    }
}
