import SwiftUI
import SwiftData
import FuelLogShared

struct AppClipRootView: View {
    @Query(filter: #Predicate<Vehicle> { !$0.isArchived }, sort: \Vehicle.name)
    private var vehicles: [Vehicle]

    /// Drives the fuel-entry sheet via `.sheet(item:)` so the tapped vehicle is
    /// always passed through reliably.
    @State private var entryTarget: EntryTarget?
    /// Parsed from the App Clip invocation URL (e.g. a station QR code). Applied
    /// to the fuel-entry form so the clip tailors itself to how it was launched.
    @State private var pendingPrefill: AppClipPrefill?
    /// Set when launched from a "share for logging" link; presents the scoped
    /// submit form for the borrowed vehicle.
    @State private var sharedTarget: SharedEntryTarget?

    var body: some View {
        NavigationStack {
            Group {
                if vehicles.isEmpty {
                    ContentUnavailableView(
                        "No Vehicles Found",
                        systemImage: "car.fill",
                        description: Text("Open the full Fuel Log app to add a vehicle first.")
                    )
                } else {
                    List(vehicles) { vehicle in
                        Button {
                            entryTarget = EntryTarget(vehicle: vehicle)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vehicle.name)
                                        .font(.headline)
                                    let subtitle = vehicleSubtitle(vehicle)
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Fuel Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let clipURL = URL(string: "https://inputfuellog.app/") {
                        ShareLink(item: clipURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(item: $entryTarget) { target in
                NavigationStack {
                    AppClipFuelEntryView(vehicle: target.vehicle, prefill: pendingPrefill)
                }
            }
            .sheet(item: $sharedTarget) { target in
                NavigationStack {
                    AppClipFuelEntryView(descriptor: target.descriptor)
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { handleInvocation(url: url) }
            }
            .onOpenURL { url in handleInvocation(url: url) }
        }
    }

    // MARK: - Invocation handling

    /// Applies the App Clip invocation URL: captures any prefill values and, when
    /// the URL names a vehicle we can resolve, jumps straight into logging for it.
    private func handleInvocation(url: URL) {
        // A share-for-logging link carries a token + full vehicle descriptor, so
        // go straight into the scoped submit form; this works even when the clip
        // has no local data (the borrower's store is empty).
        if let descriptor = SharedVehicleDescriptor(url: url) {
            sharedTarget = SharedEntryTarget(descriptor: descriptor)
            return
        }
        // Otherwise treat it as a same-account prefill / deep link.
        guard let prefill = AppClipPrefill(url: url) else { return }
        pendingPrefill = prefill
        if let token = prefill.vehicleToken, let vehicle = resolveVehicle(token: token) {
            entryTarget = EntryTarget(vehicle: vehicle)
        }
    }

    private func resolveVehicle(token: String) -> Vehicle? {
        if let uuid = UUID(uuidString: token), let match = vehicles.first(where: { $0.id == uuid }) {
            return match
        }
        return vehicles.first { $0.name.caseInsensitiveCompare(token) == .orderedSame }
            ?? vehicles.first { $0.name.localizedCaseInsensitiveContains(token) }
    }

    private func vehicleSubtitle(_ vehicle: Vehicle) -> String {
        var parts: [String] = []
        if let year = vehicle.year, year > 0 { parts.append(String(year)) }
        if !vehicle.make.isEmpty { parts.append(vehicle.make) }
        if !vehicle.model.isEmpty { parts.append(vehicle.model) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Fuel Entry Target

/// Identifiable wrapper so the fuel-entry sheet is driven by `.sheet(item:)`.
/// `.sheet(isPresented:)` combined with a separate selected-id state could
/// present before that id propagated, producing a blank sheet.
struct EntryTarget: Identifiable {
    let vehicle: Vehicle
    var id: UUID { vehicle.id }
}

/// Identifiable wrapper for presenting the shared-vehicle (borrowed car) submit form.
struct SharedEntryTarget: Identifiable {
    let descriptor: SharedVehicleDescriptor
    var id: UUID { descriptor.token }
}

// MARK: - App Clip Invocation Prefill

/// Values parsed from the App Clip invocation URL query, e.g.
/// `https://inputfuellog.app/?vehicle=My%20Civic&station=Shell&price=3.59`.
/// All fields are optional; the initializer returns nil when the URL carries
/// nothing useful, so the clip falls back to its plain vehicle-list experience.
struct AppClipPrefill {
    var vehicleToken: String?
    var station: String?
    var volume: Double?
    var price: Double?
    var odometer: Double?
    var notes: String?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let raw = items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        func number(_ name: String) -> Double? {
            value(name).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        }

        vehicleToken = value("vehicle")
        station = value("station")
        notes = value("notes")
        volume = number("volume")
        price = number("price")
        odometer = number("odometer")

        if vehicleToken == nil && station == nil && notes == nil
            && volume == nil && price == nil && odometer == nil {
            return nil
        }
    }
}

#Preview("App Clip - with vehicles") {
    let container = try! ModelContainer(
        for: FuelLogContainer.sharedSchema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let vehicle = Vehicle(
        name: "My Civic",
        make: "Honda",
        model: "Civic",
        year: 2022,
        fuelType: .gas
    )
    container.mainContext.insert(vehicle)
    return AppClipRootView()
        .modelContainer(container)
}
