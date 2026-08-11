import Foundation
import SwiftData
import WidgetKit
import FuelLogShared

// MARK: - Widget Snapshot Updater

/// Computes a lightweight snapshot of vehicle data and writes it to the shared
/// App Group UserDefaults so widgets can render without touching SwiftData/CloudKit.
enum WidgetSnapshotUpdater {
    static func update(from context: ModelContext, lastSelectedVehicleID: String) {
        let vehicles = (try? context.fetch(FetchDescriptor<Vehicle>())) ?? []
        let mapped = vehicles.filter { !$0.isArchived }.map { makeVehicle($0) }
        let selectedID = UUID(uuidString: lastSelectedVehicleID) ?? mapped.first?.id
        let snapshot = FuelLogWidgetSnapshot(lastSelectedVehicleID: selectedID, vehicles: mapped)

        if let suite = UserDefaults(suiteName: FuelLogWidgetSnapshot.appGroupIdentifier),
           let data = try? JSONEncoder().encode(snapshot) {
            suite.set(data, forKey: FuelLogWidgetSnapshot.storeKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func makeVehicle(_ v: Vehicle) -> FuelLogWidgetVehicle {
        let calendar = Calendar.current
        let now = Date()

        // Average efficiency, in the vehicle's chosen efficiency unit. Delegates
        // to the model so partial fill-ups and unit conversion stay consistent
        // with the in-app value.
        let averageEfficiency: Double? = v.averageEfficiency

        // This month fuel spend
        let monthInterval = calendar.dateInterval(of: .month, for: now)
            ?? DateInterval(start: now, duration: 60 * 60 * 24 * 31)
        let thisMonthSpend = (v.fillUps ?? []).filter { monthInterval.contains($0.date) }.map(\.totalCost).reduce(0, +)

        // Maintenance: whichever comes first (mirrors SmartRemindersManager)
        let relevantServices = v.fuelType == .electric
            ? (v.services ?? [])
            : (v.services ?? []).filter { $0.type == .oilChange }
        let lastServiceOdometer = relevantServices.map(\.odometer).max() ?? 0
        let lastServiceDate = relevantServices.map(\.date).max() ?? v.purchaseDate ?? now
        let nextServiceOdometer = lastServiceOdometer + v.maintenanceInterval
        let currentOdometer = v.lastOdometer
        let remainingDistance = currentOdometer.map { nextServiceOdometer - $0 }

        let fills = (v.fillUps ?? []).compactMap { f -> (Date, Double)? in
            guard let o = f.odometer else { return nil }
            return (f.date, o)
        }
        let services = (v.services ?? []).map { ($0.date, $0.odometer) }
        let allLogs = (fills + services).sorted { $0.0 < $1.0 }

        var mileagePredictedDate: Date?
        if let first = allLogs.first, let last = allLogs.last, last.0.timeIntervalSince(first.0) > 86400 {
            let days = last.0.timeIntervalSince(first.0) / 86400.0
            let odometerDelta = last.1 - first.1
            if odometerDelta > 0, let remaining = remainingDistance {
                let perDay = odometerDelta / days
                mileagePredictedDate = last.0.addingTimeInterval((remaining / perDay) * 86400)
            }
        }

        let timeBasedDate = calendar.date(byAdding: .month, value: max(1, Int(v.maintenanceIntervalMonths)), to: lastServiceDate) ?? now
        var maintenanceNextDate = mileagePredictedDate ?? timeBasedDate
        if let predicted = mileagePredictedDate, predicted < timeBasedDate {
            maintenanceNextDate = predicted
        }
        let isMaintenanceDue = (remainingDistance.map { $0 <= 0 } ?? false) || maintenanceNextDate <= now

        return FuelLogWidgetVehicle(
            id: v.id,
            name: v.name,
            make: v.make,
            model: v.model,
            odometerUnitRaw: v.odometerUnitRaw,
            fuelUnitRaw: v.fuelUnitRaw,
            efficiencyUnitRaw: v.efficiencyUnitRaw,
            currencyRaw: v.currencyRaw,
            isElectric: v.fuelType == .electric,
            lastOdometer: v.lastOdometer,
            averageEfficiency: averageEfficiency,
            thisMonthSpend: thisMonthSpend,
            lastFillUpDate: (v.fillUps ?? []).map(\.date).max(),
            isMaintenanceDue: isMaintenanceDue,
            maintenanceNextDate: maintenanceNextDate,
            maintenanceRemainingDistance: remainingDistance,
            maintenanceInterval: v.maintenanceInterval,
            maintenanceIntervalMonths: v.maintenanceIntervalMonths
        )
    }
}
