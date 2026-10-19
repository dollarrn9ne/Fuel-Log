import SwiftUI
import SwiftData
import MapKit
import FuelLogShared

/// Finds map positions for stops that exist only as a name.
///
/// A CSV from an older export, or from another app, has no coordinates, so every
/// stop it creates sits at "no position" and never gets a pin. This looks each
/// name up in Apple Maps after an import (and on demand from Settings).
///
/// Wrong pins are worse than none, so a result is only taken when it fits the
/// name: the brand has to appear in the result's name, and when the stop names a
/// place - "Costco (Citrus Heights)" - that place has to appear in its address.
/// Anything else stays unpinned, and the name is remembered as a miss so an
/// automatic run doesn't search for it again.
@MainActor @Observable
final class LocationGeocoder {
    static let shared = LocationGeocoder()
    private init() {}

    private(set) var isRunning = false
    private(set) var total = 0
    private(set) var processed = 0
    private(set) var found = 0
    /// Summary of the last run, for Settings.
    private(set) var lastResult: String?

    private static let missesKey = "locationGeocodeMisses"
    /// Apple Maps allows roughly 50 searches a minute; stay under that.
    private static let pause: Duration = .milliseconds(1400)
    private static let throttleBackoff: Duration = .seconds(60)

    // MARK: - Matching (pure)

    /// A stop's name split into what to search for and what to check results against.
    struct Query: Equatable {
        var text: String
        var brand: String
        var place: String?
    }

    /// "Costco (Citrus Heights)" -> brand "Costco", place "Citrus Heights",
    /// search text "Costco Citrus Heights".
    nonisolated static func query(for name: String) -> Query {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
            let brand = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            let place = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !brand.isEmpty {
                return Query(text: place.isEmpty ? brand : "\(brand) \(place)", brand: brand, place: place.isEmpty ? nil : place)
            }
        }
        return Query(text: trimmed, brand: trimmed, place: nil)
    }

    /// Lowercased letters and digits only, so "Love's" and "Loves" compare equal.
    private nonisolated static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Words too generic to say where a stop is.
    private nonisolated static let genericWords: Set<String> = [
        "north", "south", "east", "west", "airport", "road", "street", "highway", "hwy",
        "exit", "travel", "center", "stop", "station", "gas", "fuel"
    ]

    /// Lowercased words of at least three characters, plus two-digit numbers
    /// ("76" is a brand). "Elk Grove - Sheldon" -> ["elk", "grove", "sheldon"].
    nonisolated static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
            .filter { $0.count >= 3 || ($0.count == 2 && $0.allSatisfy(\.isNumber)) }
    }

    nonisolated static func firstToken(_ text: String) -> String? { tokens(text).first }

    /// Whether a map result is plausibly the stop named by `query`.
    nonisolated static func accepts(itemName: String, address: String, query: Query) -> Bool {
        let name = normalized(itemName)
        if let place = query.place {
            // Brand by its first word (chains name themselves many ways: "Costco"
            // vs "Costco Wholesale"), plus a real place word as a whole word in the
            // address ("Sunrise & Greenback" -> "...Greenback Ln, Citrus Heights").
            guard let brandToken = firstToken(query.brand), name.contains(normalized(brandToken)) else { return false }
            let placeWords = tokens(place).filter { !genericWords.contains($0) }
            // A place made only of generic words ("SF Airport") says too little to
            // tell one branch from another, so it isn't trusted.
            guard !placeWords.isEmpty else { return false }
            let addressWords = Set(tokens(address))
            return placeWords.contains { addressWords.contains($0) }
        }
        // No place to check, so hold the name to the whole brand: "Maverik" must
        // find a Maverik, and "Home Garage" must not settle for a Home Depot.
        let brand = normalized(query.brand)
        return brand.count >= 3 && name.contains(brand)
    }

    // MARK: - Running

    func fillMissingInBackground(modelContext: ModelContext, retryMisses: Bool = false) {
        guard !isRunning else { return }
        Task { await fillMissing(modelContext: modelContext, retryMisses: retryMisses) }
    }

    func fillMissing(modelContext: ModelContext, retryMisses: Bool = false) async {
        guard !isRunning else { return }
        let locations = (try? modelContext.fetch(FetchDescriptor<GasLocation>())) ?? []
        var misses = retryMisses ? Set<String>() : Set(UserDefaults.standard.stringArray(forKey: Self.missesKey) ?? [])
        let byName = Dictionary(grouping: locations.filter { !$0.hasCoordinates }) {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = byName.keys.filter { !$0.isEmpty && !misses.contains($0) }.sorted()
        guard !names.isEmpty else {
            lastResult = "Every stop already has a map position, or was already tried."
            return
        }

        // Where the stops already placed are. A bare name ("Costco", no city) would
        // otherwise match the first Costco in the world, so those searches are held
        // to this area - and skipped while nothing has a position yet.
        var placedLatitudes = locations.filter(\.hasCoordinates).map(\.latitude)
        var placedLongitudes = locations.filter(\.hasCoordinates).map(\.longitude)

        isRunning = true
        total = names.count
        processed = 0
        found = 0
        lastResult = nil
        var stoppedEarly = false
        defer { isRunning = false }

        for name in names {
            if Task.isCancelled { stoppedEarly = true; break }
            let query = Self.query(for: name)
            let anchor = Self.median(latitudes: placedLatitudes, longitudes: placedLongitudes)
            if query.place == nil, anchor == nil {
                // Nothing to anchor a bare name to yet; not a miss, so a later run can try.
                processed += 1
                continue
            }
            var coordinate: CLLocationCoordinate2D?
            do {
                coordinate = try await lookup(query, near: anchor)
            } catch where (error as? MKError)?.code == .loadingThrottled {
                // Over the search limit: wait it out once, then give up for now.
                try? await Task.sleep(for: Self.throttleBackoff)
                coordinate = try? await lookup(query, near: anchor)
                if coordinate == nil { stoppedEarly = true; break }
            } catch {
                coordinate = nil
            }

            if let coordinate {
                for location in byName[name] ?? [] {
                    location.latitude = coordinate.latitude
                    location.longitude = coordinate.longitude
                }
                found += 1
                placedLatitudes.append(coordinate.latitude)
                placedLongitudes.append(coordinate.longitude)
            } else {
                misses.insert(name)
            }
            processed += 1
            if processed % 10 == 0 { try? modelContext.save() }
            try? await Task.sleep(for: Self.pause)
        }

        try? modelContext.save()
        UserDefaults.standard.set(Array(misses), forKey: Self.missesKey)
        lastResult = stoppedEarly
            ? "Placed \(found) of \(total) stops before Apple Maps asked to slow down. Run it again later for the rest."
            : "Placed \(found) of \(total) stops. The rest couldn't be matched by name and city."
    }

    /// The middle of the placed stops (median, so one far-off pin doesn't drag it).
    nonisolated static func median(latitudes: [Double], longitudes: [Double]) -> CLLocationCoordinate2D? {
        guard !latitudes.isEmpty, latitudes.count == longitudes.count else { return nil }
        func mid(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return CLLocationCoordinate2D(latitude: mid(latitudes), longitude: mid(longitudes))
    }

    /// How far from the other stops a bare-name result may be.
    private static let bareNameRadius: CLLocationDistance = 400_000

    /// The best acceptable result for `query`, or nil. A query with no place is
    /// searched around `anchor` and only accepted within `bareNameRadius` of it.
    private func lookup(_ query: Query, near anchor: CLLocationCoordinate2D?) async throws -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.text
        request.resultTypes = .pointOfInterest
        if query.place == nil, let anchor {
            request.region = MKCoordinateRegion(center: anchor, latitudinalMeters: Self.bareNameRadius * 2, longitudinalMeters: Self.bareNameRadius * 2)
        }
        let response = try await MKLocalSearch(request: request).start()
        for item in response.mapItems.prefix(5) {
            let placemark = item.placemark
            let address = [placemark.title, placemark.locality, placemark.subLocality, placemark.administrativeArea]
                .compactMap { $0 }
                .joined(separator: " ")
            guard Self.accepts(itemName: item.name ?? "", address: address, query: query) else { continue }
            if query.place == nil, let anchor {
                let distance = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    .distance(from: CLLocation(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude))
                guard distance <= Self.bareNameRadius else { continue }
            }
            return placemark.coordinate
        }
        return nil
    }
}
