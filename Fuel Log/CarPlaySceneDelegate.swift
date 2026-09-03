//
//  CarPlaySceneDelegate.swift
//  Fuel Log
//

import CarPlay
import SwiftData
import FuelLogShared

/// Entry point CarPlay uses once it connects to the app.
///
/// Root is a plain vehicle list (CPListTemplate, legal for every CarPlay
/// category) that pushes into a per-vehicle CPInformationTemplate - that push
/// destination is gated to the parking/EV-charging/food-ordering entitlement
/// family, which the CarPlay Fueling category rides on
/// (com.apple.developer.carplay-charging, granted 2026-09-02). No text entry
/// or logging actions here on purpose: CarPlay's guidelines expect a Fueling
/// app to stay glanceable while driving, not host a form.
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
    /// widget already surfaces. Selecting a row pushes that vehicle's detail.
    private func makeVehicleListTemplate() -> CPListTemplate {
        let vehicles = fetchVehicles()
        let items: [CPListItem] = vehicles.map { vehicle in
            let item = CPListItem(text: vehicle.name, detailText: vehicleSummary(vehicle))
            item.handler = { [weak self] _, completion in
                self?.pushDetail(for: vehicle)
                completion()
            }
            return item
        }
        let section = items.isEmpty
            ? CPListSection(items: [CPListItem(text: "No Vehicles", detailText: "Add a vehicle in Fuel Log to see it here.")])
            : CPListSection(items: items)
        return CPListTemplate(title: "Fuel Log", sections: [section])
    }

    private func pushDetail(for vehicle: Vehicle) {
        interfaceController?.pushTemplate(makeInformationTemplate(for: vehicle), animated: true, completion: nil)
    }

    /// The Fueling-category detail screen: a glanceable readout, not a form.
    /// Layout is .leading rather than .twoColumn since these rows read as a
    /// short list of facts, not paired comparisons.
    private func makeInformationTemplate(for vehicle: Vehicle) -> CPInformationTemplate {
        var items: [CPInformationItem] = []
        if let odo = vehicle.lastOdometer {
            items.append(CPInformationItem(title: "Odometer", detail: "\(Int(odo)) \(vehicle.odometerUnit.rawValue.lowercased())"))
        }
        if let eff = vehicle.averageEfficiency {
            items.append(CPInformationItem(title: "Avg Efficiency", detail: "\(String(format: "%.1f", eff)) \(vehicle.efficiencyUnit.rawValue)"))
        }
        if let lastFillUp = (vehicle.fillUps ?? []).sorted(by: { $0.date > $1.date }).first {
            items.append(CPInformationItem(title: "Last Fill-Up", detail: lastFillUp.date.formatted(date: .abbreviated, time: .omitted)))
        }
        if items.isEmpty {
            items.append(CPInformationItem(title: "No Data", detail: "Log a fill-up in Fuel Log to see stats here."))
        }
        return CPInformationTemplate(title: vehicle.name, layout: .leading, items: items, actions: [])
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
