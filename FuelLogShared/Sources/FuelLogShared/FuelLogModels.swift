import Foundation
import SwiftData
import CoreLocation

// MARK: - Efficiency Conversion

public enum EfficiencyConverter {
    public static func convert(distance: Double, odometerUnit: OdometerUnit, volume: Double, fuelUnit: FuelUnit, to efficiencyUnit: EfficiencyUnit) -> Double {
        let miles = odometerUnit == .kilometers ? distance * 0.621371 : distance
        let km = miles * 1.609344
        let gallons = fuelUnit == .liters ? volume * 0.264172 : volume
        let liters = fuelUnit == .gallons ? volume * 3.78541 : volume

        switch efficiencyUnit {
        case .mpgUS:
            return gallons > 0 ? miles / gallons : 0
        case .mpgUK:
            let imperialGallons = gallons * 0.832674184
            return imperialGallons > 0 ? miles / imperialGallons : 0
        case .l100km:
            return km > 0 ? (liters / km) * 100 : 0
        case .kmPerLitre:
            return liters > 0 ? km / liters : 0
        case .miPerKWh:
            return volume > 0 ? miles / volume : 0
        case .kmPerKWh:
            return volume > 0 ? km / volume : 0
        }
    }
}

// MARK: - Vehicle

@Model public final class Vehicle {
    public var id: UUID = UUID()
    public var name: String = ""
    public var make: String = ""
    public var model: String = ""
    public var year: Int?

    @Attribute(.externalStorage) public var photoData: Data?

    public var fuelTypeRaw: String = FuelType.gas.rawValue
    public var odometerUnitRaw: String = OdometerUnit.miles.rawValue
    public var fuelUnitRaw: String = FuelUnit.gallons.rawValue
    public var efficiencyUnitRaw: String = EfficiencyUnit.mpgUS.rawValue
    public var currencyRaw: String = Currency.usd.rawValue
    /// The grade this vehicle normally takes. Used to preselect new fill-ups and
    /// to interpret older fill-ups that predate per-fill grade tracking, so users
    /// don't have to restate it every time or backfill their history.
    public var defaultGradeRaw: String?
    /// Free-text name when the default grade is `.other` (e.g. "Race Fuel").
    public var customGradeLabel: String?
    public var tankCapacity: Double?
    public var batteryCapacity: Double?
    /// Whether this vehicle has an SCR system that takes AdBlue / DEF. Off by
    /// default: older diesels don't have one, so it's a per-vehicle choice.
    public var usesAdBlue: Bool = false
    /// Size of the AdBlue / DEF tank, in the vehicle's fuel unit (litres or gallons).
    public var adBlueCapacity: Double?

    public var maintenanceInterval: Double = 5000.0
    public var maintenanceIntervalMonths: Double = 6.0

    public var purchaseDate: Date?
    public var purchasePrice: Double?
    public var currentValue: Double?
    public var isArchived: Bool = false

    // CloudKit strict rule: Arrays MUST be Optional.
    @Relationship(deleteRule: .cascade, inverse: \FillUp.vehicle) public var fillUps: [FillUp]?
    @Relationship(deleteRule: .cascade, inverse: \ServiceRecord.vehicle) public var services: [ServiceRecord]?
    @Relationship(deleteRule: .cascade, inverse: \Trip.vehicle) public var trips: [Trip]?

    @Transient public var fuelType: FuelType {
        get { FuelType(rawValue: fuelTypeRaw) ?? .gas }
        set { fuelTypeRaw = newValue.rawValue }
    }

    @Transient public var odometerUnit: OdometerUnit {
        get { OdometerUnit(rawValue: odometerUnitRaw) ?? .miles }
        set { odometerUnitRaw = newValue.rawValue }
    }

    @Transient public var fuelUnit: FuelUnit {
        get { FuelUnit(rawValue: fuelUnitRaw) ?? .gallons }
        set { fuelUnitRaw = newValue.rawValue }
    }

    @Transient public var efficiencyUnit: EfficiencyUnit {
        get { EfficiencyUnit(rawValue: efficiencyUnitRaw) ?? .mpgUS }
        set { efficiencyUnitRaw = newValue.rawValue }
    }

    @Transient public var currency: Currency {
        get { Currency(rawValue: currencyRaw) ?? .usd }
        set { currencyRaw = newValue.rawValue }
    }

    /// The vehicle's usual grade. Falls back to the one implied by its fuel type
    /// (diesel cars take diesel), so single-fuel vehicles need no configuration.
    @Transient public var defaultFuelGrade: FuelGrade? {
        get { defaultGradeRaw.flatMap { FuelGrade(rawValue: $0) } ?? fuelType.defaultGrade }
        set { defaultGradeRaw = newValue?.rawValue }
    }

    public init(id: UUID = UUID(), name: String, make: String = "", model: String = "", year: Int? = nil, fuelType: FuelType = .gas, odometerUnit: OdometerUnit = .miles, fuelUnit: FuelUnit = .gallons, efficiencyUnit: EfficiencyUnit = .mpgUS, currency: Currency = .usd, tankCapacity: Double? = nil, batteryCapacity: Double? = nil) {
        self.id = id; self.name = name; self.make = make; self.model = model; self.year = year
        self.fuelTypeRaw = fuelType.rawValue
        self.odometerUnitRaw = odometerUnit.rawValue
        self.fuelUnitRaw = fuelUnit.rawValue
        self.efficiencyUnitRaw = efficiencyUnit.rawValue
        self.currencyRaw = currency.rawValue
        self.tankCapacity = tankCapacity
        self.batteryCapacity = batteryCapacity
    }

    @Transient public var averageEfficiency: Double? { averageEfficiency(forGradeNamed: nil) }

    /// Average efficiency in the vehicle's chosen unit. Pass a `grade` to measure
    /// only the tanks filled with that fuel, so (for example) a flex-fuel driver
    /// can compare E85 against gasoline instead of averaging them together.
    ///
    /// A segment counts toward the requested grade only when the fuel added since
    /// the previous full tank was all of that grade; mixed segments are skipped
    /// because the distance can't be attributed to one fuel.
    /// - Parameter name: the fuel's display name, or nil for every fuel together.
    ///   Named rather than a `FuelGrade`, because two custom fuels are both stored
    ///   as `.other` and matching on the case alone averaged them together.
    public func averageEfficiency(forGradeNamed name: String?) -> Double? {
        let sorted = (fillUps ?? []).sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        let electricEfficiency = efficiencyUnit == .miPerKWh || efficiencyUnit == .kmPerKWh
        var dist: Double = 0, vol: Double = 0
        // Roll partial fill-ups into the next full-tank segment: a full tank
        // "closes" a measurement window, and the fuel used to cover the distance
        // since the previous full tank is the sum of every fill-up in between
        // (including the closing full tank, excluding the opening one).
        var lastFullOdo: Double? = nil
        var volumeSinceLastFull: Double = 0
        var segmentMatchesGrade = true
        for fill in sorted {
            // Only mix fill-ups whose energy type matches the efficiency unit.
            if (fill.unit == .kwh) != electricEfficiency { continue }
            guard let odo = fill.odometer else { continue }
            volumeSinceLastFull += fill.volume
            if let name, fill.effectiveGradeName != name { segmentMatchesGrade = false }
            if fill.isFullTank {
                if let prevOdo = lastFullOdo, odo > prevOdo, segmentMatchesGrade {
                    dist += (odo - prevOdo)
                    vol += volumeSinceLastFull
                }
                lastFullOdo = odo
                volumeSinceLastFull = 0
                segmentMatchesGrade = true
            }
        }
        guard vol > 0, dist > 0 else { return nil }
        return EfficiencyConverter.convert(distance: dist, odometerUnit: odometerUnit, volume: vol, fuelUnit: fuelUnit, to: efficiencyUnit)
    }

    /// Efficiency of each full-tank fill-up, keyed by fill-up id, in the
    /// vehicle's efficiency unit - the per-log counterpart of
    /// `averageEfficiency`, and built from the same full-tank-to-full-tank
    /// segments so the two always agree.
    ///
    /// A full tank "closes" a segment: distance since the previous *full* tank,
    /// divided by every fill-up since then (any partial fill-ups in between plus
    /// the closing one). Measuring only from the immediately preceding fill-up
    /// - which is what the log rows, charts and widget used to do - gave the
    /// wrong figure after a partial fill: the closing fill refills what was
    /// burned since the *full* tank, not just since the partial one (e.g. 150mi
    /// / 7.5gal = 20 MPG shown, against a true 300mi / 10gal = 30 MPG).
    ///
    /// Fill-ups that aren't full tanks, have no odometer, or whose energy type
    /// doesn't match the efficiency unit (a plug-in's charges) get no entry.
    public func segmentEfficiencies() -> [UUID: Double] {
        let sorted = (fillUps ?? []).sorted { $0.date < $1.date }
        let electricEfficiency = efficiencyUnit == .miPerKWh || efficiencyUnit == .kmPerKWh
        var result: [UUID: Double] = [:]
        var lastFullOdo: Double? = nil
        var volumeSinceLastFull: Double = 0
        for fill in sorted {
            if (fill.unit == .kwh) != electricEfficiency { continue }
            guard let odo = fill.odometer else { continue }
            volumeSinceLastFull += fill.volume
            if fill.isFullTank {
                if let prevOdo = lastFullOdo, odo > prevOdo, volumeSinceLastFull > 0 {
                    result[fill.id] = EfficiencyConverter.convert(distance: odo - prevOdo, odometerUnit: odometerUnit, volume: volumeSinceLastFull, fuelUnit: fuelUnit, to: efficiencyUnit)
                }
                lastFullOdo = odo
                volumeSinceLastFull = 0
            }
        }
        return result
    }

    /// kWh a charge from `start`% to `end`% would add, from the battery
    /// capacity. Used to offer a starting value when the user knows the battery
    /// percentages but not the kWh; nil without a capacity or a real gain.
    public func estimatedKWh(fromSoC start: Double, toSoC end: Double) -> Double? {
        // A plug-in hybrid has a separate battery size. A pure EV's single
        // "Capacity (kWh)" field is stored as tankCapacity, so fall back to it.
        let capacity = batteryCapacity ?? (fuelType == .electric ? tankCapacity : nil)
        guard let capacity, capacity > 0, end > start else { return nil }
        return capacity * (end - start) / 100.0
    }

    /// "L" or "gal" for AdBlue / DEF volumes, following the vehicle's fuel unit.
    public var fluidUnitLabel: String { fuelUnit == .gallons ? "gal" : "L" }

    // MARK: Full-tank sanity check

    /// A "full tank" fill-up smaller than this share of the vehicle's usual
    /// full tank is probably a partial fill with the Full Tank switch left on.
    public static let smallFullTankFraction: Double = 0.6

    /// Fewest earlier full-tank fill-ups needed before their sizes are trusted
    /// as "usual" when no tank capacity has been entered.
    private static let minimumFillUpsForUsualTank = 3

    /// What this vehicle normally takes to fill from empty-ish, in its own fuel
    /// unit: the entered tank capacity if there is one, otherwise the median size
    /// of its earlier full-tank fill-ups (needs a few, so a new vehicle gets no
    /// answer rather than a bad one). Charging is excluded. Pass the id of a
    /// fill-up being edited so it isn't compared against itself.
    public func usualFullTankVolume(excluding excludedID: UUID? = nil) -> Double? {
        if let capacity = tankCapacity, capacity > 0 { return capacity }
        let volumes = (fillUps ?? [])
            .filter { $0.isFullTank && $0.unit != .kwh && $0.volume > 0 && $0.id != excludedID }
            .map(\.volume)
            .sorted()
        guard volumes.count >= Self.minimumFillUpsForUsualTank else { return nil }
        let mid = volumes.count / 2
        return volumes.count % 2 == 0 ? (volumes[mid - 1] + volumes[mid]) / 2 : volumes[mid]
    }

    /// True when `volume` (in the vehicle's fuel unit) is far enough below the
    /// usual full tank that flagging it "full" will probably skew MPG.
    public func isSuspiciouslySmallFullTank(volume: Double, excluding excludedID: UUID? = nil) -> Bool {
        guard volume > 0, let usual = usualFullTankVolume(excluding: excludedID) else { return false }
        return volume < usual * Self.smallFullTankFraction
    }

    /// Average efficiency per fuel grade, for grades that have enough data to
    /// produce a figure. Ordered by `FuelGrade`'s declaration order.
    /// One row per fuel actually used, keyed on the name shown to the user.
    ///
    /// Keyed on the name rather than the `FuelGrade` case: two fuels the user
    /// named themselves are both stored as `.other`, so keying on the case
    /// collapsed them into a single "Other" row whose figure averaged both and
    /// whose label discarded both names.
    @Transient public var efficiencyByGrade: [(name: String, efficiency: Double)] {
        let usedNames = Set((fillUps ?? []).compactMap(\.effectiveGradeName))
        guard usedNames.count > 1 else { return [] }
        // Standard grades keep their canonical order; custom names have no case
        // to order by, so they follow, alphabetically.
        let ordered = usedNames.sorted { lhs, rhs in
            let l = FuelGrade.allCases.firstIndex { $0.rawValue == lhs } ?? FuelGrade.allCases.count
            let r = FuelGrade.allCases.firstIndex { $0.rawValue == rhs } ?? FuelGrade.allCases.count
            return l == r ? lhs < rhs : l < r
        }
        return ordered.compactMap { name in
            guard let value = averageEfficiency(forGradeNamed: name) else { return nil }
            return (name, value)
        }
    }

    /// Average price paid per unit for a grade, for cost-per-distance comparisons.
    /// Named rather than a `FuelGrade`, for the same reason as
    /// `averageEfficiency(forGradeNamed:)`: custom fuels share the `.other` case.
    public func averagePrice(forGradeNamed name: String) -> Double? {
        let matching = (fillUps ?? []).filter { $0.effectiveGradeName == name && $0.volume > 0 }
        guard !matching.isEmpty else { return nil }
        let volume = matching.map(\.volume).reduce(0, +)
        guard volume > 0 else { return nil }
        return matching.map(\.totalCost).reduce(0, +) / volume
    }

    @Transient public var totalCost: Double { totalFuelCost + totalServiceCost }
    @Transient public var totalFuelCost: Double { (fillUps ?? []).map(\.totalCost).reduce(0, +) }
    @Transient public var totalServiceCost: Double { (services ?? []).map(\.cost).reduce(0, +) }

    @Transient public var totalDistanceLogged: Double {
        let odos = ((fillUps ?? []).compactMap(\.odometer) + (services ?? []).compactMap(\.odometer))
        guard let minOdo = odos.min(), let maxOdo = odos.max(), maxOdo > minOdo else { return 0 }
        return maxOdo - minOdo
    }

    @Transient public var lastOdometer: Double? { (fillUps ?? []).compactMap(\.odometer).max() ?? (services ?? []).compactMap(\.odometer).max() }

    @Transient public var isMaintenanceDue: Bool {
        guard let current = lastOdometer else { return false }
        let relevantServices = fuelType == .electric ? (services ?? []) : (services ?? []).filter({ $0.type == .oilChange })
        // Never serviced yet -> due.
        guard let lastServiceOdo = relevantServices.map(\.odometer).max() else { return true }
        // Distance-based: driven past the mileage interval since the last service.
        if (current - lastServiceOdo) >= maintenanceInterval { return true }
        // Time-based: elapsed past the month interval since the last service.
        // Reminders and the widget use whichever limit is reached first, so the
        // in-app alert must too.
        if let lastServiceDate = relevantServices.map(\.date).max(),
           let dueDate = Calendar.current.date(byAdding: .month, value: max(1, Int(maintenanceIntervalMonths)), to: lastServiceDate) {
            if Date() >= dueDate { return true }
        }
        return false
    }
}

// MARK: - FillUp

@Model public final class FillUp {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var odometer: Double?
    public var volume: Double = 0.0
    public var pricePerUnit: Double = 0.0
    public var isFullTank: Bool = true
    public var notes: String = ""
    public var unitRaw: String = FuelUnit.gallons.rawValue
    /// What went in the tank (E85, Regular, ...). Optional so existing records
    /// migrate without a version bump; nil means "not recorded".
    public var gradeRaw: String?
    /// Free-text name when the grade is `.other` (e.g. "Race Fuel").
    public var customGradeLabel: String?
    public var vehicle: Vehicle?
    public var location: GasLocation?

    // EV charging session details. All optional so existing records (and every
    // gas fill-up) migrate untouched; nil means "not recorded".
    /// `ChargerType` raw value: home, public Level 2, or DC fast.
    public var chargerTypeRaw: String?
    /// Battery state of charge, in percent (0-100), when the session started/ended.
    public var startSoC: Double?
    public var endSoC: Double?
    /// How long the session lasted, in minutes.
    public var durationMinutes: Int?
    /// Flat per-session fee charged on top of the energy (public networks).
    public var sessionFee: Double?
    /// Name of the home rate plan this charge was priced with, and how many of
    /// its kWh fell in the off-peak window. `pricePerUnit` already holds the
    /// blended result, so totals never depend on the plan still existing.
    public var ratePlanName: String?
    public var offPeakKWh: Double?

    @Attribute(.externalStorage) public var receiptData: Data?

    @Transient public var unit: FuelUnit {
        get { FuelUnit(rawValue: unitRaw) ?? .gallons }
        set { unitRaw = newValue.rawValue }
    }

    @Transient public var chargerType: ChargerType? {
        get { chargerTypeRaw.flatMap { ChargerType(rawValue: $0) } }
        set { chargerTypeRaw = newValue?.rawValue }
    }

    /// Average power over the session, in kW: energy added divided by time.
    /// Nil unless this is a charge with a recorded duration.
    @Transient public var averageChargingKW: Double? {
        guard unit == .kwh, let minutes = durationMinutes else { return nil }
        return FillUp.averageChargingKW(kWh: volume, minutes: minutes)
    }

    /// Percentage points gained, when both ends of the session were recorded.
    @Transient public var socGain: Double? {
        guard let startSoC, let endSoC, endSoC > startSoC else { return nil }
        return endSoC - startSoC
    }

    /// "38 min", "1 h", "1 h 25 min" - compact enough for a log row.
    public static func durationText(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }

    /// kWh / hours. Shared with the entry form so it can show the figure live,
    /// before anything is saved.
    public static func averageChargingKW(kWh: Double, minutes: Int) -> Double? {
        guard kWh > 0, minutes > 0 else { return nil }
        return kWh / (Double(minutes) / 60.0)
    }

    @Transient public var fuelGrade: FuelGrade? {
        get { gradeRaw.flatMap { FuelGrade(rawValue: $0) } }
        set { gradeRaw = newValue?.rawValue }
    }

    /// The grade to treat this fill-up as: what was recorded, otherwise the
    /// vehicle's usual grade. This lets fill-ups logged before grade tracking
    /// existed count toward the right grade without rewriting stored data, and
    /// keeps following the vehicle if its default is changed later.
    @Transient public var effectiveGrade: FuelGrade? {
        // Charging has no fuel grade.
        guard unit != .kwh else { return nil }
        return fuelGrade ?? vehicle?.defaultFuelGrade
    }

    /// What to show the user for this fill-up's grade: the custom name when the
    /// grade is "Other", otherwise the grade itself. Falls back to the vehicle's
    /// configured label for entries that predate per-fill grade tracking.
    @Transient public var effectiveGradeName: String? {
        guard let grade = effectiveGrade else { return nil }
        guard grade == .other else { return grade.rawValue }
        let own = customGradeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        // Inherited from the vehicle only when this fill-up has no grade of its own.
        if fuelGrade == nil, let inherited = vehicle?.customGradeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !inherited.isEmpty {
            return inherited
        }
        return grade.rawValue
    }

    public init(id: UUID = UUID(), date: Date = .now, odometer: Double? = nil, volume: Double, pricePerUnit: Double, isFullTank: Bool = true, notes: String = "", unit: FuelUnit = .gallons, grade: FuelGrade? = nil, vehicle: Vehicle? = nil, location: GasLocation? = nil, receiptData: Data? = nil, chargerType: ChargerType? = nil, startSoC: Double? = nil, endSoC: Double? = nil, durationMinutes: Int? = nil, sessionFee: Double? = nil, ratePlanName: String? = nil, offPeakKWh: Double? = nil) {
        self.id = id; self.date = date; self.odometer = odometer; self.volume = volume; self.pricePerUnit = pricePerUnit; self.isFullTank = isFullTank; self.notes = notes
        self.unitRaw = unit.rawValue
        self.gradeRaw = grade?.rawValue
        self.vehicle = vehicle; self.location = location; self.receiptData = receiptData
        self.chargerTypeRaw = chargerType?.rawValue
        self.startSoC = startSoC; self.endSoC = endSoC; self.durationMinutes = durationMinutes; self.sessionFee = sessionFee
        self.ratePlanName = ratePlanName; self.offPeakKWh = offPeakKWh
    }
    /// Energy plus any flat session fee - what the session actually cost. Every
    /// total (dashboard, reports, charts) goes through this, so a fee is counted
    /// everywhere without each caller knowing about it.
    @Transient public var totalCost: Double { volume * pricePerUnit + (sessionFee ?? 0) }
}

// MARK: - AdBlue / DEF insights

/// How much AdBlue / DEF a vehicle uses, what it costs, and roughly how far the
/// tank will last. Pure over the vehicle's services, so it can be checked on its
/// own with fixed inputs.
///
/// Consumption is measured between full top-ups, with any partial top-ups in
/// between rolled into the next full one - the same method as MPG between full
/// tanks. Measuring from the volume of every top-up regardless would be wrong
/// whenever the tank wasn't filled to the same level each time.
public struct AdBlueInsights {
    /// Top-ups logged with a volume.
    public let topUps: Int
    public let totalVolume: Double
    public let totalCost: Double
    /// Volume used per 1,000 distance units (the vehicle's odometer unit). nil
    /// until two full top-ups bracket some distance.
    public let consumptionPer1000: Double?
    public let costPer1000: Double?
    /// Fluid left in the tank, from the last full top-up, the typical rate and the
    /// distance driven since. nil unless the tank size is set and the latest
    /// top-up filled the tank.
    public let remainingVolume: Double?
    public let remainingFraction: Double?
    /// Distance the remaining fluid should cover.
    public let rangeLeft: Double?

    /// At or below this share of the tank is "low".
    public static let lowFraction: Double = 0.2

    public var isLow: Bool { (remainingFraction ?? 1) <= Self.lowFraction }

    public init(vehicle: Vehicle) {
        let services = (vehicle.services ?? [])
            .filter { $0.type == .adBlue && ($0.volume ?? 0) > 0 }
            .sorted { $0.date < $1.date }
        topUps = services.count
        totalVolume = services.map { $0.volume ?? 0 }.reduce(0, +)
        totalCost = services.map(\.cost).reduce(0, +)

        var distance = 0.0, volume = 0.0, cost = 0.0
        var lastFullOdometer: Double? = nil
        var volumeSince = 0.0, costSince = 0.0
        for service in services {
            volumeSince += service.volume ?? 0
            costSince += service.cost
            guard service.filledToFull ?? true else { continue }
            if let previous = lastFullOdometer, service.odometer > previous {
                distance += service.odometer - previous
                volume += volumeSince
                cost += costSince
            }
            lastFullOdometer = service.odometer
            volumeSince = 0
            costSince = 0
        }
        let rate: Double? = (distance > 0 && volume > 0) ? volume / distance * 1000 : nil
        consumptionPer1000 = rate
        costPer1000 = distance > 0 ? cost / distance * 1000 : nil

        if let rate, let capacity = vehicle.adBlueCapacity, capacity > 0,
           let last = services.last, last.filledToFull ?? true {
            let current = max(vehicle.lastOdometer ?? last.odometer, last.odometer)
            let used = rate / 1000 * (current - last.odometer)
            let remaining = max(0, capacity - used)
            remainingVolume = remaining
            remainingFraction = remaining / capacity
            rangeLeft = remaining / (rate / 1000)
        } else {
            remainingVolume = nil
            remainingFraction = nil
            rangeLeft = nil
        }
    }
}

// MARK: - Charging insights

/// Summary figures over a set of EV charging sessions: how much energy, what it
/// cost per kWh (session fees included), how fast it charged, and how home
/// charging compares with public. Pure over the fill-ups it's given, so a
/// timeframe filter just passes fewer of them.
public struct ChargingInsights {
    /// One row of the by-charger-type breakdown. `type` is nil for sessions that
    /// didn't record one.
    public struct TypeSummary: Identifiable {
        public let type: ChargerType?
        public let sessions: Int
        public let kWh: Double
        public let cost: Double
        /// Energy-weighted average over sessions that recorded a duration.
        public let avgKW: Double?
        public var id: String { type?.rawValue ?? "Not Recorded" }
        public var title: String { type?.rawValue ?? "Not Recorded" }
        public var avgCostPerKWh: Double? { kWh > 0 ? cost / kWh : nil }
    }

    public struct SpeedPoint: Identifiable {
        public let id: UUID
        public let date: Date
        public let kW: Double
        public let type: ChargerType?
    }

    public let sessions: Int
    public let totalKWh: Double
    public let totalCost: Double
    /// Total energy divided by total time, over sessions that recorded a duration -
    /// so one long slow overnight charge isn't averaged equally with a short fast one.
    public let avgKW: Double?
    public let fastestKW: Double?
    public let byType: [TypeSummary]
    public let speedPoints: [SpeedPoint]
    /// Home's share of the energy / spend among sessions whose charger type is
    /// known; nil unless both home and public charging are present.
    public let homeEnergyShare: Double?
    public let homeCostShare: Double?

    public var avgCostPerKWh: Double? { totalKWh > 0 ? totalCost / totalKWh : nil }

    public init(fillUps: [FillUp]) {
        let charges = fillUps.filter { $0.unit == .kwh && $0.volume > 0 }
        sessions = charges.count
        totalKWh = charges.map(\.volume).reduce(0, +)
        totalCost = charges.map(\.totalCost).reduce(0, +)

        func averageKW(_ list: [FillUp]) -> Double? {
            let timed = list.filter { ($0.durationMinutes ?? 0) > 0 }
            let hours = timed.map { Double($0.durationMinutes ?? 0) / 60.0 }.reduce(0, +)
            guard hours > 0 else { return nil }
            return timed.map(\.volume).reduce(0, +) / hours
        }
        avgKW = averageKW(charges)
        fastestKW = charges.compactMap(\.averageChargingKW).max()

        let order: [ChargerType?] = [.home, .publicLevel2, .dcFast, nil]
        byType = order.compactMap { type in
            let group = charges.filter { $0.chargerType == type }
            guard !group.isEmpty else { return nil }
            return TypeSummary(type: type, sessions: group.count, kWh: group.map(\.volume).reduce(0, +), cost: group.map(\.totalCost).reduce(0, +), avgKW: averageKW(group))
        }

        speedPoints = charges
            .sorted { $0.date < $1.date }
            .compactMap { fill in fill.averageChargingKW.map { SpeedPoint(id: fill.id, date: fill.date, kW: $0, type: fill.chargerType) } }

        let home = byType.first { $0.type == .home }
        let publicTypes = byType.filter { $0.type == .publicLevel2 || $0.type == .dcFast }
        if let home, !publicTypes.isEmpty {
            let publicKWh = publicTypes.map(\.kWh).reduce(0, +)
            let publicCost = publicTypes.map(\.cost).reduce(0, +)
            homeEnergyShare = (home.kWh + publicKWh) > 0 ? home.kWh / (home.kWh + publicKWh) : nil
            homeCostShare = (home.cost + publicCost) > 0 ? home.cost / (home.cost + publicCost) : nil
        } else {
            homeEnergyShare = nil
            homeCostShare = nil
        }
    }
}

// MARK: - ServiceRecord

@Model public final class ServiceRecord {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var odometer: Double = 0.0
    public var typeRaw: String = ServiceType.general.rawValue
    public var cost: Double = 0.0
    public var notes: String = ""
    public var vehicle: Vehicle?
    public var location: GasLocation?
    /// Litres or gallons of fluid added, for an AdBlue / DEF top-up (the vehicle's
    /// fuel unit). nil for every other kind of service.
    public var volume: Double?
    /// Whether an AdBlue / DEF top-up filled the tank. Consumption can only be
    /// measured between full top-ups (the same idea as MPG between full tanks).
    /// nil means not recorded, which is treated as full.
    public var filledToFull: Bool?

    @Attribute(.externalStorage) public var receiptData: Data?

    @Transient public var type: ServiceType {
        get { ServiceType(rawValue: typeRaw) ?? .general }
        set { typeRaw = newValue.rawValue }
    }

    public init(id: UUID = UUID(), date: Date = .now, odometer: Double, type: ServiceType, cost: Double, notes: String = "", vehicle: Vehicle? = nil, location: GasLocation? = nil, receiptData: Data? = nil, volume: Double? = nil, filledToFull: Bool? = nil) {
        self.id = id; self.date = date; self.odometer = odometer
        self.typeRaw = type.rawValue
        self.cost = cost; self.notes = notes; self.vehicle = vehicle; self.location = location; self.receiptData = receiptData
        self.volume = volume; self.filledToFull = filledToFull
    }
}

// MARK: - GasLocation

@Model public final class GasLocation {
    public var id: UUID = UUID()
    public var name: String = ""
    public var latitude: Double = 0.0
    public var longitude: Double = 0.0

    @Relationship(deleteRule: .nullify, inverse: \FillUp.location) public var fillUps: [FillUp]?
    @Relationship(deleteRule: .nullify, inverse: \ServiceRecord.location) public var services: [ServiceRecord]?

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude
    }
}

public extension GasLocation {
    /// Two stations nearer than this are taken to be the same forecourt, so
    /// re-logging at one reuses its record instead of piling up duplicate pins.
    static let samePlaceRadiusMetres: Double = 150

    /// The record for a station, or nil when a new one is needed.
    ///
    /// Matches on name *and* position. Name alone folded distinct stations that
    /// share a brand into one record - every Chevron in the state became a single
    /// pin - and since the match returned the existing record untouched, later
    /// logs silently inherited the first one's coordinates.
    static func matching(name: String, latitude: Double, longitude: Double, in candidates: [GasLocation]) -> GasLocation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.first { candidate in
            guard candidate.name.caseInsensitiveCompare(trimmed) == .orderedSame else { return false }
            // Records from CSV import and Shortcuts carry no coordinates, so
            // there is nothing to compare and the name has to stand on its own.
            guard candidate.hasCoordinates, latitude != 0 || longitude != 0 else { return true }
            let a = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
            return a.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= samePlaceRadiusMetres
        }
    }

    var hasCoordinates: Bool { latitude != 0 || longitude != 0 }
}

// MARK: - TripCategory

@Model public final class TripCategory {
    public var id: UUID = UUID()
    public var name: String = ""
    @Relationship(deleteRule: .nullify, inverse: \Trip.category) public var trips: [Trip]?

    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

// MARK: - Trip

@Model public final class Trip {
    public var id: UUID = UUID()
    public var name: String = ""
    public var startDate: Date = Date()
    public var endDate: Date = Date()
    public var startOdometer: Double?
    public var endOdometer: Double?
    public var category: TripCategory?
    public var vehicle: Vehicle?

    @Transient public var distance: Double? {
        guard let s = startOdometer, let e = endOdometer, e >= s else { return nil }
        return e - s
    }

    public init(id: UUID = UUID(), name: String, startDate: Date = .now, endDate: Date = .now, startOdometer: Double? = nil, endOdometer: Double? = nil, category: TripCategory? = nil, vehicle: Vehicle? = nil) {
        self.id = id; self.name = name; self.startDate = startDate; self.endDate = endDate; self.startOdometer = startOdometer; self.endOdometer = endOdometer; self.category = category; self.vehicle = vehicle
    }
}

// MARK: - ShareToken

/// Records a "share for logging" link the owner created for a vehicle. The
/// owner's app imports public FuelSubmission records tagged with an active
/// token; revoking flips `isActive` so submissions are ignored.
@Model public final class ShareToken {
    public var id: UUID = UUID()
    public var token: UUID = UUID()
    public var vehicleID: UUID = UUID()
    public var vehicleName: String = ""
    public var createdAt: Date = Date()
    public var isActive: Bool = true

    public init(id: UUID = UUID(), token: UUID = UUID(), vehicleID: UUID, vehicleName: String = "", createdAt: Date = Date(), isActive: Bool = true) {
        self.id = id
        self.token = token
        self.vehicleID = vehicleID
        self.vehicleName = vehicleName
        self.createdAt = createdAt
        self.isActive = isActive
    }
}
