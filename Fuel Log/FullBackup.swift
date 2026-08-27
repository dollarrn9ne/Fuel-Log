import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import FuelLogShared

// MARK: - JSON Backup Document

struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}

// MARK: - Backup Payload

struct BackupEnvelope: Codable {
    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var vehicles: [BackupVehicle]
    var gasLocations: [BackupGasLocation]
    var tripCategories: [BackupTripCategory]
}

struct BackupVehicle: Codable {
    var id: UUID
    var name: String
    var make: String
    var model: String
    var year: Int?
    var photoData: Data?
    var fuelTypeRaw: String
    var odometerUnitRaw: String
    var fuelUnitRaw: String
    var efficiencyUnitRaw: String
    var currencyRaw: String
    /// Optional so backups predating vehicle-level fuel grades still decode.
    var defaultGradeRaw: String?
    var customGradeLabel: String?
    var tankCapacity: Double?
    var batteryCapacity: Double?
    var maintenanceInterval: Double
    var maintenanceIntervalMonths: Double
    var purchaseDate: Date?
    var purchasePrice: Double?
    var currentValue: Double?
    var isArchived: Bool
    var fillUps: [BackupFillUp]
    var services: [BackupService]
    var trips: [BackupTrip]
}

struct BackupFillUp: Codable {
    var id: UUID
    var date: Date
    var odometer: Double?
    var volume: Double
    var pricePerUnit: Double
    var isFullTank: Bool
    var notes: String
    var unitRaw: String
    /// Optional so backups written before fuel grades existed still decode.
    var gradeRaw: String?
    var customGradeLabel: String?
    var locationID: UUID?
    var receiptData: Data?
}

struct BackupService: Codable {
    var id: UUID
    var date: Date
    var odometer: Double
    var typeRaw: String
    var cost: Double
    var notes: String
    var locationID: UUID?
    var receiptData: Data?
}

struct BackupGasLocation: Codable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
}

struct BackupTripCategory: Codable {
    var id: UUID
    var name: String
}

struct BackupTrip: Codable {
    var id: UUID
    var name: String
    var startDate: Date
    var endDate: Date
    var startOdometer: Double?
    var endOdometer: Double?
    var categoryID: UUID?
}

// MARK: - Backup Engine

enum BackupError: LocalizedError {
    case unsupportedFormat
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This backup file is not supported by this version of Fuel Log."
        case .invalidData:
            return "The backup file could not be read. It may be corrupted."
        }
    }
}

@MainActor
enum FullBackup {
    static let currentFormatVersion = 1

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }
        return decoder
    }

    static func exportData(context: ModelContext) throws -> Data {
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>(sortBy: [SortDescriptor(\Vehicle.name)]))
        let gasLocations = try context.fetch(FetchDescriptor<GasLocation>(sortBy: [SortDescriptor(\GasLocation.name)]))
        let categories = try context.fetch(FetchDescriptor<TripCategory>(sortBy: [SortDescriptor(\TripCategory.name)]))

        let envelope = BackupEnvelope(
            formatVersion: currentFormatVersion,
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            vehicles: vehicles.map { v in
                BackupVehicle(
                    id: v.id, name: v.name, make: v.make, model: v.model, year: v.year, photoData: v.photoData,
                    fuelTypeRaw: v.fuelTypeRaw, odometerUnitRaw: v.odometerUnitRaw, fuelUnitRaw: v.fuelUnitRaw,
                    efficiencyUnitRaw: v.efficiencyUnitRaw, currencyRaw: v.currencyRaw,
                    defaultGradeRaw: v.defaultGradeRaw, customGradeLabel: v.customGradeLabel,
                    tankCapacity: v.tankCapacity, batteryCapacity: v.batteryCapacity,
                    maintenanceInterval: v.maintenanceInterval, maintenanceIntervalMonths: v.maintenanceIntervalMonths,
                    purchaseDate: v.purchaseDate, purchasePrice: v.purchasePrice, currentValue: v.currentValue,
                    isArchived: v.isArchived,
                    fillUps: (v.fillUps ?? []).sorted { $0.date < $1.date }.map { f in
                        BackupFillUp(id: f.id, date: f.date, odometer: f.odometer, volume: f.volume, pricePerUnit: f.pricePerUnit,
                                     isFullTank: f.isFullTank, notes: f.notes, unitRaw: f.unitRaw, gradeRaw: f.gradeRaw,
                                     customGradeLabel: f.customGradeLabel,
                                     locationID: f.location?.id, receiptData: f.receiptData)
                    },
                    services: (v.services ?? []).sorted { $0.date < $1.date }.map { s in
                        BackupService(id: s.id, date: s.date, odometer: s.odometer, typeRaw: s.typeRaw, cost: s.cost,
                                      notes: s.notes, locationID: s.location?.id, receiptData: s.receiptData)
                    },
                    trips: (v.trips ?? []).sorted { $0.startDate < $1.startDate }.map { t in
                        BackupTrip(id: t.id, name: t.name, startDate: t.startDate, endDate: t.endDate,
                                   startOdometer: t.startOdometer, endOdometer: t.endOdometer, categoryID: t.category?.id)
                    }
                )
            },
            gasLocations: gasLocations.map { BackupGasLocation(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude) },
            tripCategories: categories.map { BackupTripCategory(id: $0.id, name: $0.name) }
        )
        return try encoder.encode(envelope)
    }

    /// Where the pre-restore snapshot is parked. Left behind if a restore fails
    /// so the data is recoverable by hand even if the app is killed mid-way.
    static var safetyCopyURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PreRestoreSafetyCopy.json")
    }

    /// The snapshot left behind by a restore that didn't finish, if there is one.
    ///
    /// Its presence at launch is the signal that a restore failed part way: the
    /// file is written before the deletes and removed only on success.
    static var pendingSafetyCopy: Data? {
        guard let url = safetyCopyURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Throws the snapshot away, for when the user would rather keep what's
    /// currently in the app than roll back to it.
    static func discardSafetyCopy() {
        guard let url = safetyCopyURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Restores a backup, replacing everything currently stored.
    ///
    /// The deletes below are batch operations that hit the store immediately, so
    /// once they run there is nothing to fall back on if the rebuild then fails.
    /// The current contents are therefore snapshotted first: kept in memory to
    /// roll back from, and written to disk so a crash mid-restore is still
    /// recoverable. The file is removed once the restore succeeds.
    ///
    /// Decoding happens before any of that, so a corrupt or future-format file
    /// throws without touching the store at all.
    @discardableResult
    static func restore(from data: Data, context: ModelContext) throws -> Int {
        let envelope = try decodeEnvelope(from: data)
        let safetyCopy = try? exportData(context: context)
        // Never overwrite an existing snapshot. If one is already on disk then an
        // earlier restore failed and this call is most likely the recovery
        // attempt - writing now would replace the good copy with the broken state
        // it is trying to undo, and a second failure would leave nothing to
        // return to.
        if let safetyCopy, let url = safetyCopyURL,
           !FileManager.default.fileExists(atPath: url.path) {
            try? safetyCopy.write(to: url, options: .atomic)
        }

        do {
            try apply(envelope, context: context)
        } catch {
            // Put back what was there. Best effort: if this fails too, the file
            // written above is the remaining route back.
            if let safetyCopy, let previous = try? decodeEnvelope(from: safetyCopy) {
                try? apply(previous, context: context)
            }
            throw error
        }

        if let url = safetyCopyURL { try? FileManager.default.removeItem(at: url) }
        return envelope.vehicles.count
    }

    private static func decodeEnvelope(from data: Data) throws -> BackupEnvelope {
        let envelope: BackupEnvelope
        do {
            envelope = try decoder.decode(BackupEnvelope.self, from: data)
        } catch {
            throw BackupError.invalidData
        }
        guard envelope.formatVersion == currentFormatVersion else { throw BackupError.unsupportedFormat }
        return envelope
    }

    /// Replaces the store's contents with the envelope's. Assumes the caller has
    /// already decoded and snapshotted.
    private static func apply(_ envelope: BackupEnvelope, context: ModelContext) throws {
        try context.delete(model: Vehicle.self)
        try context.delete(model: Trip.self)
        try context.delete(model: TripCategory.self)
        try context.delete(model: GasLocation.self)

        var gasLocations: [UUID: GasLocation] = [:]
        for gl in envelope.gasLocations {
            let object = GasLocation(id: gl.id, name: gl.name, latitude: gl.latitude, longitude: gl.longitude)
            context.insert(object)
            gasLocations[gl.id] = object
        }

        var categories: [UUID: TripCategory] = [:]
        for c in envelope.tripCategories {
            let object = TripCategory(id: c.id, name: c.name)
            context.insert(object)
            categories[c.id] = object
        }

        for vehicle in envelope.vehicles {
            let object = Vehicle(
                id: vehicle.id, name: vehicle.name, make: vehicle.make, model: vehicle.model, year: vehicle.year,
                fuelType: FuelType(rawValue: vehicle.fuelTypeRaw) ?? .gas,
                odometerUnit: OdometerUnit(rawValue: vehicle.odometerUnitRaw) ?? .miles,
                fuelUnit: FuelUnit(rawValue: vehicle.fuelUnitRaw) ?? .gallons,
                efficiencyUnit: EfficiencyUnit(rawValue: vehicle.efficiencyUnitRaw) ?? .mpgUS,
                currency: Currency(rawValue: vehicle.currencyRaw) ?? .usd,
                tankCapacity: vehicle.tankCapacity, batteryCapacity: vehicle.batteryCapacity
            )
            object.photoData = vehicle.photoData
            object.defaultGradeRaw = vehicle.defaultGradeRaw
            object.customGradeLabel = vehicle.customGradeLabel
            object.maintenanceInterval = vehicle.maintenanceInterval
            object.maintenanceIntervalMonths = vehicle.maintenanceIntervalMonths
            object.purchaseDate = vehicle.purchaseDate
            object.purchasePrice = vehicle.purchasePrice
            object.currentValue = vehicle.currentValue
            object.isArchived = vehicle.isArchived
            context.insert(object)

            for fillUp in vehicle.fillUps {
                let restoredFillUp = FillUp(
                    id: fillUp.id, date: fillUp.date, odometer: fillUp.odometer, volume: fillUp.volume,
                    pricePerUnit: fillUp.pricePerUnit, isFullTank: fillUp.isFullTank, notes: fillUp.notes,
                    unit: FuelUnit(rawValue: fillUp.unitRaw) ?? .gallons,
                    grade: fillUp.gradeRaw.flatMap { FuelGrade(rawValue: $0) },
                    vehicle: object, location: fillUp.locationID.flatMap { gasLocations[$0] },
                    receiptData: fillUp.receiptData
                )
                restoredFillUp.customGradeLabel = fillUp.customGradeLabel
                context.insert(restoredFillUp)
            }
            for service in vehicle.services {
                context.insert(ServiceRecord(
                    id: service.id, date: service.date, odometer: service.odometer,
                    type: ServiceType(rawValue: service.typeRaw) ?? .general, cost: service.cost,
                    notes: service.notes, vehicle: object, location: service.locationID.flatMap { gasLocations[$0] },
                    receiptData: service.receiptData
                ))
            }
            for trip in vehicle.trips {
                context.insert(Trip(
                    id: trip.id, name: trip.name, startDate: trip.startDate, endDate: trip.endDate,
                    startOdometer: trip.startOdometer, endOdometer: trip.endOdometer,
                    category: trip.categoryID.flatMap { categories[$0] }, vehicle: object
                ))
            }
        }

        try context.save()
    }
}
