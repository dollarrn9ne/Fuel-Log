import Foundation
import SwiftData

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
    public var tankCapacity: Double?
    public var batteryCapacity: Double?

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

    @Transient public var averageEfficiency: Double? { averageEfficiency(forGrade: nil) }

    /// Average efficiency in the vehicle's chosen unit. Pass a `grade` to measure
    /// only the tanks filled with that fuel, so (for example) a flex-fuel driver
    /// can compare E85 against gasoline instead of averaging them together.
    ///
    /// A segment counts toward the requested grade only when the fuel added since
    /// the previous full tank was all of that grade; mixed segments are skipped
    /// because the distance can't be attributed to one fuel.
    public func averageEfficiency(forGrade grade: FuelGrade?) -> Double? {
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
            if let grade, fill.fuelGrade != grade { segmentMatchesGrade = false }
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

    /// Average efficiency per fuel grade, for grades that have enough data to
    /// produce a figure. Ordered by `FuelGrade`'s declaration order.
    @Transient public var efficiencyByGrade: [(grade: FuelGrade, efficiency: Double)] {
        let usedGrades = Set((fillUps ?? []).compactMap(\.fuelGrade))
        guard usedGrades.count > 1 else { return [] }
        return FuelGrade.allCases.compactMap { grade in
            guard usedGrades.contains(grade), let value = averageEfficiency(forGrade: grade) else { return nil }
            return (grade, value)
        }
    }

    /// Average price paid per unit for a grade, for cost-per-distance comparisons.
    public func averagePrice(forGrade grade: FuelGrade) -> Double? {
        let matching = (fillUps ?? []).filter { $0.fuelGrade == grade && $0.volume > 0 }
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
    public var vehicle: Vehicle?
    public var location: GasLocation?

    @Attribute(.externalStorage) public var receiptData: Data?

    @Transient public var unit: FuelUnit {
        get { FuelUnit(rawValue: unitRaw) ?? .gallons }
        set { unitRaw = newValue.rawValue }
    }

    @Transient public var fuelGrade: FuelGrade? {
        get { gradeRaw.flatMap { FuelGrade(rawValue: $0) } }
        set { gradeRaw = newValue?.rawValue }
    }

    public init(id: UUID = UUID(), date: Date = .now, odometer: Double? = nil, volume: Double, pricePerUnit: Double, isFullTank: Bool = true, notes: String = "", unit: FuelUnit = .gallons, grade: FuelGrade? = nil, vehicle: Vehicle? = nil, location: GasLocation? = nil, receiptData: Data? = nil) {
        self.id = id; self.date = date; self.odometer = odometer; self.volume = volume; self.pricePerUnit = pricePerUnit; self.isFullTank = isFullTank; self.notes = notes
        self.unitRaw = unit.rawValue
        self.gradeRaw = grade?.rawValue
        self.vehicle = vehicle; self.location = location; self.receiptData = receiptData
    }
    @Transient public var totalCost: Double { volume * pricePerUnit }
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

    @Attribute(.externalStorage) public var receiptData: Data?

    @Transient public var type: ServiceType {
        get { ServiceType(rawValue: typeRaw) ?? .general }
        set { typeRaw = newValue.rawValue }
    }

    public init(id: UUID = UUID(), date: Date = .now, odometer: Double, type: ServiceType, cost: Double, notes: String = "", vehicle: Vehicle? = nil, location: GasLocation? = nil, receiptData: Data? = nil) {
        self.id = id; self.date = date; self.odometer = odometer
        self.typeRaw = type.rawValue
        self.cost = cost; self.notes = notes; self.vehicle = vehicle; self.location = location; self.receiptData = receiptData
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
