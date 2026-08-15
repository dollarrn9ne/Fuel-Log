import Foundation
import CloudKit

// MARK: - Shared Logging Relay
//
// One-way relay so someone borrowing a vehicle can log a fill-up from the App
// Clip and have it land in the owner's account, without cross-account CloudKit
// sharing. The owner's app writes a share link carrying an opaque token plus a
// self-contained description of the vehicle (so the clip needs no local data).
// The clip submits a `FuelSubmission` record to the container's PUBLIC database
// tagged with that token; the owner's app fetches submissions for its tokens,
// imports them, and deletes the public record.

public enum SharedLogging {
    /// CloudKit record type in the public database.
    public static let recordType = "FuelSubmission"

    /// The associated domain used for App Clip invocation links.
    public static let linkScheme = "https"
    public static let linkHost = "inputfuellog.app"

    /// Query-item keys used in the share link.
    public enum LinkKey {
        public static let token = "token"
        public static let vehicleID = "vehicle"
        public static let name = "name"
        public static let make = "make"
        public static let model = "model"
        public static let year = "year"
        public static let fuelType = "fuelType"
        public static let fuelUnit = "fuelUnit"
        public static let odometerUnit = "odoUnit"
        public static let currency = "currency"
    }

    /// Field keys on the CloudKit `FuelSubmission` record.
    public enum Field {
        public static let token = "token"
        public static let vehicleID = "vehicleID"
        public static let date = "date"
        public static let odometer = "odometer"
        public static let volume = "volume"
        public static let pricePerUnit = "pricePerUnit"
        public static let isFullTank = "isFullTank"
        public static let unitRaw = "unitRaw"
        public static let notes = "notes"
        public static let locationName = "locationName"
        public static let submittedAt = "submittedAt"
        public static let clientSubmissionID = "clientSubmissionID"
    }
}

// MARK: - Shared Vehicle Descriptor

/// A self-contained description of the shared vehicle, encoded into the share
/// link so the App Clip can render its form (labels/units) without reading any
/// local data; the borrower's clip store is empty.
public struct SharedVehicleDescriptor: Sendable, Equatable {
    public var token: UUID
    public var vehicleID: UUID
    public var name: String
    public var make: String
    public var model: String
    public var year: Int?
    public var fuelTypeRaw: String
    public var fuelUnitRaw: String
    public var odometerUnitRaw: String
    public var currencyRaw: String

    public init(
        token: UUID,
        vehicleID: UUID,
        name: String,
        make: String = "",
        model: String = "",
        year: Int? = nil,
        fuelTypeRaw: String,
        fuelUnitRaw: String,
        odometerUnitRaw: String,
        currencyRaw: String
    ) {
        self.token = token
        self.vehicleID = vehicleID
        self.name = name
        self.make = make
        self.model = model
        self.year = year
        self.fuelTypeRaw = fuelTypeRaw
        self.fuelUnitRaw = fuelUnitRaw
        self.odometerUnitRaw = odometerUnitRaw
        self.currencyRaw = currencyRaw
    }

    // Convenience typed accessors.
    public var fuelType: FuelType { FuelType(rawValue: fuelTypeRaw) ?? .gas }
    public var fuelUnit: FuelUnit { FuelUnit(rawValue: fuelUnitRaw) ?? .gallons }
    public var odometerUnit: OdometerUnit { OdometerUnit(rawValue: odometerUnitRaw) ?? .miles }
    public var currency: Currency { Currency(rawValue: currencyRaw) ?? .usd }
    public var isElectric: Bool { fuelType == .electric }

    /// The App Clip invocation link that carries this descriptor.
    public var shareURL: URL {
        var components = URLComponents()
        components.scheme = SharedLogging.linkScheme
        components.host = SharedLogging.linkHost
        components.path = "/"
        var items: [URLQueryItem] = [
            URLQueryItem(name: SharedLogging.LinkKey.token, value: token.uuidString),
            URLQueryItem(name: SharedLogging.LinkKey.vehicleID, value: vehicleID.uuidString),
            URLQueryItem(name: SharedLogging.LinkKey.name, value: name),
            URLQueryItem(name: SharedLogging.LinkKey.fuelType, value: fuelTypeRaw),
            URLQueryItem(name: SharedLogging.LinkKey.fuelUnit, value: fuelUnitRaw),
            URLQueryItem(name: SharedLogging.LinkKey.odometerUnit, value: odometerUnitRaw),
            URLQueryItem(name: SharedLogging.LinkKey.currency, value: currencyRaw)
        ]
        if !make.isEmpty { items.append(URLQueryItem(name: SharedLogging.LinkKey.make, value: make)) }
        if !model.isEmpty { items.append(URLQueryItem(name: SharedLogging.LinkKey.model, value: model)) }
        if let year { items.append(URLQueryItem(name: SharedLogging.LinkKey.year, value: String(year))) }
        components.queryItems = items
        return components.url ?? URL(string: "\(SharedLogging.linkScheme)://\(SharedLogging.linkHost)/")!
    }

    /// Parses a descriptor from an App Clip invocation link. Returns nil unless
    /// the link carries both a valid `token` and `vehicle` id (i.e. it's a
    /// share-for-logging link rather than a plain launch).
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            let raw = items.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }?.value
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        guard let tokenString = value(SharedLogging.LinkKey.token), let token = UUID(uuidString: tokenString),
              let vehicleString = value(SharedLogging.LinkKey.vehicleID), let vehicleID = UUID(uuidString: vehicleString),
              let name = value(SharedLogging.LinkKey.name) else {
            return nil
        }
        self.token = token
        self.vehicleID = vehicleID
        self.name = name
        self.make = value(SharedLogging.LinkKey.make) ?? ""
        self.model = value(SharedLogging.LinkKey.model) ?? ""
        self.year = value(SharedLogging.LinkKey.year).flatMap { Int($0) }
        self.fuelTypeRaw = value(SharedLogging.LinkKey.fuelType) ?? FuelType.gas.rawValue
        self.fuelUnitRaw = value(SharedLogging.LinkKey.fuelUnit) ?? FuelUnit.gallons.rawValue
        self.odometerUnitRaw = value(SharedLogging.LinkKey.odometerUnit) ?? OdometerUnit.miles.rawValue
        self.currencyRaw = value(SharedLogging.LinkKey.currency) ?? Currency.usd.rawValue
    }
}

// MARK: - Fuel Submission Payload

/// A fill-up submitted through the relay. Foundation-only so it is usable
/// anywhere; the CloudKit mapping lives in the extension below.
public struct FuelSubmissionPayload: Sendable, Equatable {
    public var token: UUID
    public var vehicleID: UUID
    public var date: Date
    public var odometer: Double?
    public var volume: Double
    public var pricePerUnit: Double
    public var isFullTank: Bool
    public var unitRaw: String
    public var notes: String
    public var locationName: String
    public var submittedAt: Date
    /// Stable per-submission id so the owner's importer can dedupe.
    public var clientSubmissionID: String

    public init(
        token: UUID,
        vehicleID: UUID,
        date: Date,
        odometer: Double?,
        volume: Double,
        pricePerUnit: Double,
        isFullTank: Bool,
        unitRaw: String,
        notes: String,
        locationName: String,
        submittedAt: Date = Date(),
        clientSubmissionID: String = UUID().uuidString
    ) {
        self.token = token
        self.vehicleID = vehicleID
        self.date = date
        self.odometer = odometer
        self.volume = volume
        self.pricePerUnit = pricePerUnit
        self.isFullTank = isFullTank
        self.unitRaw = unitRaw
        self.notes = notes
        self.locationName = locationName
        self.submittedAt = submittedAt
        self.clientSubmissionID = clientSubmissionID
    }
}

// MARK: - CloudKit Mapping

public extension FuelSubmissionPayload {
    /// Builds a public-database CKRecord representing this submission.
    func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: SharedLogging.recordType)
        record[SharedLogging.Field.token] = token.uuidString as CKRecordValue
        record[SharedLogging.Field.vehicleID] = vehicleID.uuidString as CKRecordValue
        record[SharedLogging.Field.date] = date as CKRecordValue
        if let odometer { record[SharedLogging.Field.odometer] = odometer as CKRecordValue }
        record[SharedLogging.Field.volume] = volume as CKRecordValue
        record[SharedLogging.Field.pricePerUnit] = pricePerUnit as CKRecordValue
        record[SharedLogging.Field.isFullTank] = (isFullTank ? 1 : 0) as CKRecordValue
        record[SharedLogging.Field.unitRaw] = unitRaw as CKRecordValue
        record[SharedLogging.Field.notes] = notes as CKRecordValue
        record[SharedLogging.Field.locationName] = locationName as CKRecordValue
        record[SharedLogging.Field.submittedAt] = submittedAt as CKRecordValue
        record[SharedLogging.Field.clientSubmissionID] = clientSubmissionID as CKRecordValue
        return record
    }

    /// Reconstructs a submission from a fetched CKRecord. Returns nil if the
    /// record is missing required fields.
    init?(record: CKRecord) {
        guard let tokenString = record[SharedLogging.Field.token] as? String, let token = UUID(uuidString: tokenString),
              let vehicleString = record[SharedLogging.Field.vehicleID] as? String, let vehicleID = UUID(uuidString: vehicleString),
              let date = record[SharedLogging.Field.date] as? Date,
              let volume = record[SharedLogging.Field.volume] as? Double,
              let clientSubmissionID = record[SharedLogging.Field.clientSubmissionID] as? String else {
            return nil
        }
        self.token = token
        self.vehicleID = vehicleID
        self.date = date
        self.odometer = record[SharedLogging.Field.odometer] as? Double
        self.volume = volume
        self.pricePerUnit = (record[SharedLogging.Field.pricePerUnit] as? Double) ?? 0
        self.isFullTank = ((record[SharedLogging.Field.isFullTank] as? Int) ?? 1) != 0
        self.unitRaw = (record[SharedLogging.Field.unitRaw] as? String) ?? FuelUnit.gallons.rawValue
        self.notes = (record[SharedLogging.Field.notes] as? String) ?? ""
        self.locationName = (record[SharedLogging.Field.locationName] as? String) ?? ""
        self.submittedAt = (record[SharedLogging.Field.submittedAt] as? Date) ?? date
        self.clientSubmissionID = clientSubmissionID
    }
}
