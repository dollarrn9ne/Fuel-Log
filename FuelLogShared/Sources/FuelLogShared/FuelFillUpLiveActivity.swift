import Foundation
import ActivityKit

// MARK: - Fuel Fill-Up Live Activity

/// Describes a fill-up that is currently being entered.
/// The type identity is shared between the app (which starts / updates / ends the
/// activity) and the widget extension (which renders the lock screen / Dynamic Island UI).
public struct FuelFillUpAttributes: ActivityAttributes {
    public var vehicleName: String
    public var fuelUnitRaw: String
    public var currencyRaw: String

    public struct ContentState: Codable, Hashable {
        public var volume: Double
        public var pricePerUnit: Double
        public var totalCost: Double
        public var unitRaw: String
        public var currencyRaw: String

        public init(volume: Double, pricePerUnit: Double, totalCost: Double, unitRaw: String, currencyRaw: String) {
            self.volume = volume
            self.pricePerUnit = pricePerUnit
            self.totalCost = totalCost
            self.unitRaw = unitRaw
            self.currencyRaw = currencyRaw
        }
    }

    public init(vehicleName: String, fuelUnitRaw: String, currencyRaw: String) {
        self.vehicleName = vehicleName
        self.fuelUnitRaw = fuelUnitRaw
        self.currencyRaw = currencyRaw
    }
}
