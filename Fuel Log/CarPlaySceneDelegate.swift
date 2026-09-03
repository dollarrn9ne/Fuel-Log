//
//  CarPlaySceneDelegate.swift
//  Fuel Log
//

import CarPlay
import SwiftData
import FuelLogShared

/// Entry point CarPlay uses once it connects to the app.
///
/// Deliberately generic - a plain list, not any of the category-gated
/// templates (CPPointOfInterestTemplate, CPInformationTemplate, etc.) - since
/// which of those are even legal depends on the CarPlay category Apple
/// grants, still pending as of writing. CPListTemplate is available to every
/// CarPlay category, so this gives CarPlay something correct to show in the
/// Simulator now without committing to a shape that might have to be redone
/// once the entitlement comes back.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeVehicleListTemplate(), animated: true, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    /// One row per vehicle, with the same odometer/efficiency figures the
    /// widget already surfaces.
    private func makeVehicleListTemplate() -> CPListTemplate {
        let vehicles = fetchVehicles()
        let items: [CPListItem] = vehicles.map { vehicle in
            CPListItem(text: vehicle.name, detailText: vehicleSummary(vehicle))
        }
        let section = items.isEmpty
            ? CPListSection(items: [CPListItem(text: "No Vehicles", detailText: "Add a vehicle in Fuel Log to see it here.")])
            : CPListSection(items: items)
        return CPListTemplate(title: "Fuel Log", sections: [section])
    }

    private func fetchVehicles() -> [Vehicle] {
        guard let container = SharedModelContainer.current else { return [] }
        let context = ModelContext(container)
        return (try? context.fetch(FetchDescriptor<Vehicle>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private func vehicleSummary(_ vehicle: Vehicle) -> String {
        var parts: [String] = []
        if let odo = vehicle.lastOdometer {
            parts.append("\(Int(odo)) \(vehicle.odometerUnit.rawValue.lowercased())")
        }
        if let eff = vehicle.averageEfficiency {
            parts.append("\(String(format: "%.1f", eff)) \(vehicle.efficiencyUnit.rawValue)")
        }
        return parts.isEmpty ? "No logs yet" : parts.joined(separator: " • ")
    }
}
