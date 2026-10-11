import SwiftUI
import SwiftData
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
    // Charging session details - own electric vehicles only; the shared-vehicle
    // relay has no fields for them.
    @State private var chargerType: ChargerType?
    @State private var startSoCStr: String = ""
    @State private var endSoCStr: String = ""
    @State private var hoursStr: String = ""
    @State private var minutesStr: String = ""
    @State private var sessionFeeStr: String = ""

    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmitShared = false

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

    /// Charging details are stored on the device, so they're only offered when
    /// logging for the user's own electric vehicle.
    private var showsChargingSession: Bool {
        if case .local(let v) = mode { return v.fuelType == .electric }
        return false
    }

    private var sessionFeeApplies: Bool { showsChargingSession && chargerType != .home }

    private var sessionFeeValue: Double {
        guard sessionFeeApplies else { return 0 }
        return max(0, Double(sessionFeeStr.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    private var durationMinutesValue: Int? {
        let total = max(0, Int(hoursStr) ?? 0) * 60 + max(0, Int(minutesStr) ?? 0)
        return total > 0 ? total : nil
    }

    /// Battery percentages, clamped to a real 0-100 range.
    private func parsedSoC(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return min(max(value, 0), 100)
    }

    /// Notice under the Full Tank switch when the amount is far below what the
    /// vehicle usually takes - same rule as the main app's Log Fuel form. Only
    /// for the user's own vehicles: a shared vehicle has no history here.
    private var smallFullTankWarning: String? {
        guard case .local(let vehicle) = mode, !isElectric, isFullTank,
              let vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")),
              vehicle.isSuspiciouslySmallFullTank(volume: vol),
              let usual = vehicle.usualFullTankVolume() else { return nil }
        return String(format: "%.1f %@ is much less than this vehicle's usual full tank (about %.1f). If you didn't fill it all the way, mark it as a partial fill so MPG isn't thrown off.", vol, vehicle.fuelUnit.rawValue.lowercased(), usual)
    }

    private var navigationTitleText: String { isElectric ? "Log Charge" : "Log Fuel" }

    private var isFormValid: Bool {
        let filled = [volumeStr, pricePerUnitStr, totalCostStr].filter { !$0.isEmpty }.count
        return filled >= 2
    }

    var body: some View {
        if didSubmitShared {
            submittedConfirmationView
        } else {
            entryForm
        }
    }

    private var submittedConfirmationView: some View {
        ContentUnavailableView {
            Label("Fill-Up Sent", systemImage: "checkmark.circle.fill")
        } description: {
            Text("This fill-up has been sent to the owner's account.")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var entryForm: some View {
        Form {
            if case .shared(let descriptor) = mode {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Logging for \(descriptor.name).")
                            Text("This fill-up will be sent to the owner.")
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
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
                    if let warning = smallFullTankWarning {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("Mark as Partial Fill") { isFullTank = false }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if showsChargingSession {
                Section("Charging Session") {
                    Picker("Charger Type", selection: $chargerType) {
                        Text("Not Recorded").tag(nil as ChargerType?)
                        ForEach(ChargerType.allCases) { type in
                            Label(type.rawValue, systemImage: type.systemImage).tag(type as ChargerType?)
                        }
                    }
                    HStack {
                        Text("Battery Start (%)")
                        TextField("e.g., 20", text: $startSoCStr)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Battery End (%)")
                        TextField("e.g., 80", text: $endSoCStr)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Hours")
                        TextField("0", text: $hoursStr)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    HStack {
                        Text("Minutes")
                        TextField("0", text: $minutesStr)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    if sessionFeeApplies {
                        HStack {
                            Text("Session Fee (\(currencyLabel))")
                            TextField("0.00", text: $sessionFeeStr)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                        }
                    }
                    if let vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")),
                       let minutes = durationMinutesValue,
                       let kw = FillUp.averageChargingKW(kWh: vol, minutes: minutes) {
                        LabeledContent("Average Speed", value: String(format: "%.1f kW", kw))
                    }
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
        .onChange(of: sessionFeeStr) { _, _ in recalculate() }
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

        let expected = v * p + sessionFeeValue
        if abs(expected - t) > 0.01 {
            totalCostStr = String(format: "%.2f", expected)
        }
    }

    // MARK: - Save

    /// The user-entered values, normalized (deriving volume or price from the
    /// total when one is omitted). Returns nil when there isn't enough to log.
    private func normalizedValues() -> (volume: Double, pricePerUnit: Double, odometer: Double?, notes: String, station: String)? {
        var vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        var ppu = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let tc = Double(totalCostStr.replacingOccurrences(of: ",", with: ".")) ?? 0

        // Total is all-in; the price per unit excludes any session fee.
        let net = max(0, tc - sessionFeeValue)
        if tc > 0 {
            if vol > 0 && ppu == 0 { ppu = net / vol }
            else if ppu > 0 && vol == 0 { vol = net / ppu }
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
            receiptData: nil,
            chargerType: showsChargingSession ? chargerType : nil,
            startSoC: showsChargingSession ? parsedSoC(startSoCStr) : nil,
            endSoC: showsChargingSession ? parsedSoC(endSoCStr) : nil,
            durationMinutes: showsChargingSession ? durationMinutesValue : nil,
            sessionFee: sessionFeeValue > 0 ? sessionFeeValue : nil
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
                var request = URLRequest(url: SharedLogging.relayEndpointURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(SharedLogging.relayClientSecret, forHTTPHeaderField: "X-Fuel-Log-Client-Secret")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload.makeRelayJSON())

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let detail = String(data: data, encoding: .utf8) ?? "unknown error"
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: detail])
                }

                await MainActor.run {
                    isSubmitting = false
                    didSubmitShared = true
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = "Your fill-up couldn’t be sent. Make sure you’re connected to the internet, then try again.\n\n(\(error.localizedDescription))"
                }
            }
        }
    }
}
