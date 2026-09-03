import Foundation
import ActivityKit
import FuelLogShared

// MARK: - Fuel Fill-Up Live Activity

enum FuelFillUpActivityManager {
    static func start(vehicleName: String, unitRaw: String, currencyRaw: String) -> Activity<FuelFillUpAttributes>? {
        let attributes = FuelFillUpAttributes(vehicleName: vehicleName, fuelUnitRaw: unitRaw, currencyRaw: currencyRaw)
        let initialState = FuelFillUpAttributes.ContentState(volume: 0, pricePerUnit: 0, totalCost: 0, unitRaw: unitRaw, currencyRaw: currencyRaw)
        do {
            return try Activity.request(attributes: attributes, content: ActivityContent(state: initialState, staleDate: nil), pushType: nil)
        } catch {
            return nil
        }
    }

    static func update(_ activity: Activity<FuelFillUpAttributes>?, volume: Double, pricePerUnit: Double, totalCost: Double) {
        guard let activity else { return }
        let state = FuelFillUpAttributes.ContentState(
            volume: volume,
            pricePerUnit: pricePerUnit,
            totalCost: totalCost,
            unitRaw: activity.attributes.fuelUnitRaw,
            currencyRaw: activity.attributes.currencyRaw
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    static func end(_ activity: Activity<FuelFillUpAttributes>?, volume: Double, pricePerUnit: Double, totalCost: Double) {
        guard let activity else { return }
        let state = FuelFillUpAttributes.ContentState(
            volume: volume,
            pricePerUnit: pricePerUnit,
            totalCost: totalCost,
            unitRaw: activity.attributes.fuelUnitRaw,
            currencyRaw: activity.attributes.currencyRaw
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
}
