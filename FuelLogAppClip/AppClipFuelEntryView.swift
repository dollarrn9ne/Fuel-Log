import SwiftUI
import SwiftData
import CloudKit
import FuelLogShared

struct AppClipFuelEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// How this entry is being logged.
    enum Mode {
        /// Logging into the local store for one of the user's own vehicles.
        case local(Vehicle)
        /// Logging on behalf of a shared vehicle (borrowed car). The fill-up is
        /// submitted to the owner's account via the public-database relay.
        case shared(SharedVehicleDescriptor)
    }

    private let mode: Mode

    @State private var date: Date = .now
    @State private var odometerStr: String = ""
    @State private var volumeStr: String = ""
    @State private var pricePerUnitStr: String = ""
    @State private var totalCostStr: String = ""
    @State private var isFullTank: Bool = true
    @State private var notes: String = ""
    @State private var locationName: String = ""

    @State private var isSubmitting = false
    @State private var submitError: String?

    init(vehicle: Vehicle, prefill: AppClipPrefill? = nil) {
        self.mode = .local(vehicle)
        _volumeStr = State(initialValue: prefill?.volume.map(Self.numberString) ?? "")
        _pricePerUnitStr = State(initialValue: prefill?.price.map(Self.numberString) ?? "")
        _odometerStr = State(initialValue: prefill?.odometer.map(Self.numberString) ?? "")
        _notes = State(initialValue: prefill?.notes ?? "")
        _locationName = State(initialValue: prefill?.station ?? "")
    }

    init(descriptor: SharedVehicleDescriptor) {
        self.mode = .shared(descriptor)
    }

    /// Compact numeric string (no trailing ".0") for seeding text fields.
    private nonisolated static func numberString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Mode-derived display

    private var isElectric: Bool {
        switch mode {
        case .local(let v): return v.fuelType == .electric
        case .shared(let d): return d.isElectric
        }
    }

    private var fuelUnitLabel: String {
        switch mode {
        case .local(let v): return v.fuelUnit.rawValue
        case .shared(let d): return d.fuelUnitRaw
        }
    }

    private var currencyLabel: String {
        switch mode {
        case .local(let v): return v.currency.rawValue
        case .shared(let d): return d.currencyRaw
        }
    }

    private var modelFuelUnit: FuelUnit {
        switch mode {
        case .local(let v): return v.fuelUnit
        case .shared(let d): return d.fuelUnit
        }
    }

    private var navigationTitleText: String { isElectric ? "Log Charge" : "Log Fuel" }

    private var isFormValid: Bool {
        let filled = [volumeStr, pricePerUnitStr, totalCostStr].filter { !$0.isEmpty }.count
        return filled >= 2
    }

    var body: some View {
        Form {
            if case .shared(let descriptor) = mode {
                Section {
                    Label("Logging for \(descriptor.name). This fill-up will be sent to the owner.",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General Info") {
                DatePicker("Date", selection: $date)
                HStack {
                    Text("Odometer")
                    TextField("0000", text: $odometerStr)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Location")
                    TextField("ex. Costco Gas - Roseville", text: $locationName)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("\(isElectric ? "Charge" : "Fuel") Details") {
                HStack {
                    Text("Volume (\(fuelUnitLabel))")
                    TextField("0.0", text: $volumeStr)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Price / \(fuelUnitLabel)")
                    TextField("0.00", text: $pricePerUnitStr)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Total Cost (\(currencyLabel))")
                    TextField("0.00", text: $totalCostStr)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                if !isElectric {
                    Toggle("Full Tank", isOn: $isFullTank)
                }
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(!isFormValid)
                }
            }
        }
        .onChange(of: volumeStr) { _, _ in recalculate() }
        .onChange(of: pricePerUnitStr) { _, _ in recalculate() }
        .onChange(of: totalCostStr) { _, _ in recalculate() }
        .alert("Couldn’t Submit", isPresented: Binding(
            get: { submitError != nil },
            set: { if !$0 { submitError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(submitError ?? "")
        }
    }

    private func recalculate() {
        let vol = Double(volumeStr.replacingOccurrences(of: ",", with: "."))
        let ppu = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: "."))
        let total = Double(totalCostStr.replacingOccurrences(of: ",", with: "."))

        guard let v = vol, let p = ppu, let t = total else { return }

        if abs(v * p - t) > 0.01 {
            totalCostStr = String(format: "%.2f", v * p)
        }
    }

    // MARK: - Save

    /// The user-entered values, normalized (deriving volume or price from the
    /// total when one is omitted). Returns nil when there isn't enough to log.
    private func normalizedValues() -> (volume: Double, pricePerUnit: Double, odometer: Double?, notes: String, station: String)? {
        var vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        var ppu = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let tc = Double(totalCostStr.replacingOccurrences(of: ",", with: ".")) ?? 0

        if tc > 0 {
            if vol > 0 && ppu == 0 { ppu = tc / vol }
            else if ppu > 0 && vol == 0 { vol = tc / ppu }
        }

        guard vol > 0 else { return nil }

        let odo = Double(odometerStr.replacingOccurrences(of: ",", with: "."))
        let finalNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let station = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (vol, ppu, odo, finalNotes, station)
    }

    private func save() {
        guard let values = normalizedValues() else { return }
        switch mode {
        case .local(let vehicle):
            saveLocal(vehicle: vehicle, values: values)
        case .shared(let descriptor):
            submitShared(descriptor: descriptor, values: values)
        }
    }

    private func saveLocal(vehicle: Vehicle, values: (volume: Double, pricePerUnit: Double, odometer: Double?, notes: String, station: String)) {
        var location: GasLocation? = nil
        if !values.station.isEmpty {
            let newLocation = GasLocation(name: values.station, latitude: 0, longitude: 0)
            modelContext.insert(newLocation)
            location = newLocation
        }

        let fillUp = FillUp(
            date: date,
            odometer: values.odometer,
            volume: values.volume,
            pricePerUnit: values.pricePerUnit,
            isFullTank: isElectric ? true : isFullTank,
            notes: values.notes,
            unit: modelFuelUnit,
            vehicle: vehicle,
            location: location,
            receiptData: nil
        )
        modelContext.insert(fillUp)
        if vehicle.fillUps == nil { vehicle.fillUps = [] }
        vehicle.fillUps?.append(fillUp)

        try? modelContext.save()
        dismiss()
    }

    /// Submits the fill-up to the owner's account via the public-database relay.
    private func submitShared(descriptor: SharedVehicleDescriptor, values: (volume: Double, pricePerUnit: Double, odometer: Double?, notes: String, station: String)) {
        isSubmitting = true
        let payload = FuelSubmissionPayload(
            token: descriptor.token,
            vehicleID: descriptor.vehicleID,
            date: date,
            odometer: values.odometer,
            volume: values.volume,
            pricePerUnit: values.pricePerUnit,
            isFullTank: isElectric ? true : isFullTank,
            unitRaw: descriptor.fuelUnitRaw,
            notes: values.notes,
            locationName: values.station
        )
        Task {
            do {
                _ = try await CKContainer.default().publicCloudDatabase.save(payload.makeRecord())
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = "Your fill-up couldn’t be sent. Make sure you’re signed in to iCloud and connected to the internet, then try again.\n\n(\(error.localizedDescription))"
                }
            }
        }
    }
}
