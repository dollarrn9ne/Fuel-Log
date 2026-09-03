import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import PhotosUI
import ActivityKit
import UniformTypeIdentifiers
import FuelLogShared

enum FillUpEntryMode: String, CaseIterable, Identifiable {
    case fuel = "Fuel"
    case charge = "Charge"
    var id: String { rawValue }
}

struct AddFillUpView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var previousLocations: [GasLocation]
    
    let vehicle: Vehicle
    var editingFillUp: FillUp?
    var entryMode: FillUpEntryMode? = nil
    
    private var isChargeMode: Bool {
        if let entryMode { return entryMode == .charge }
        if let f = editingFillUp { return f.unit == .kwh }
        return vehicle.fuelType == .electric
    }
    
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var nearbyLocations: [LocationSuggestion] = []
    
    @State private var date: Date = .now
    @State private var locationName: String = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var showingMapPicker = false
    
    @State private var isCrossBorder: Bool = false
    @State private var foreignUnit: FuelUnit = .liters
    @State private var foreignCurrency: Currency = .cad
    @AppStorage("lastExchangeRate") private var lastExchangeRate: Double = 1.0
    @State private var exchangeRateStr: String = ""
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled: Bool = true
    
    @State private var odometerStr: String = ""
    @State private var volumeStr: String = ""
    @State private var pricePerUnitStr: String = ""
    @State private var totalCostStr: String = ""
    @State private var isFullTank: Bool = true
    @State private var fuelGrade: FuelGrade?
    @State private var customGradeLabel: String = ""
    @State private var notes: String = ""
    
    // Receipt Scanning
    @State private var scannedImage: UIImage?
    @State private var isScanningReceipt = false
    @State private var isParsingReceipt = false
    @State private var showingScannerUnavailableAlert = false
    @State private var receiptPickerItem: PhotosPickerItem?
    /// Highlights the receipt row while a drag is over it. iPad's multitasking
    /// makes dragging a receipt photo in from Photos a real path, not just the
    /// scan button or the picker.
    @State private var isTargetingReceiptDrop = false

    // Live Activity (running fuel cost while filling out the form)
    @State private var liveActivity: Activity<FuelFillUpAttributes>?
    
    enum FillUpFocus { case odometer, volume, price, totalCost }
    @FocusState private var focusedField: FillUpFocus?
    @State private var recentEdits: [FillUpFocus] = []

    var locationSuggestions: [LocationSuggestion] {
        let lowerQuery = locationName.localizedLowercase
        
        // 1. Previously-entered locations first (most relevant)
        var suggestions: [LocationSuggestion] = previousLocations
            .filter { lowerQuery.isEmpty || $0.name.localizedLowercase.contains(lowerQuery) }
            .map { LocationSuggestion(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, isNearby: false) }
        
        // 2. Nearby Search Results, skipping names already shown
        for item in nearbyLocations {
            if lowerQuery.isEmpty || item.name.localizedLowercase.contains(lowerQuery) {
                if !suggestions.contains(where: { $0.name == item.name }) {
                    suggestions.append(item)
                }
            }
        }
        
        // Hide exact match
        if !lowerQuery.isEmpty {
            suggestions.removeAll { $0.name.localizedLowercase == lowerQuery }
        }
        
        return Array(suggestions.prefix(15))
    }

    var body: some View {
        Form {
            Section {
                if let scannedImage {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: scannedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity)

                        Button(action: { self.scannedImage = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.red)
                                .background(Color.white.clipShape(Circle()))
                                .padding(8)
                        }
                    }
                    .onDrop(of: [.image], isTargeted: $isTargetingReceiptDrop) { handleReceiptDrop($0) }
                } else {
                    VStack(spacing: 12) {
                        Button(action: {
                            #if targetEnvironment(simulator)
                            showingScannerUnavailableAlert = true
                            #else
                            isScanningReceipt = true
                            #endif
                        }) {
                            HStack {
                                Image(systemName: "doc.viewfinder")
                                    .font(.title2)
                                Text("Scan Receipt for Auto-Fill")
                                    .fontWeight(.semibold)
                                Spacer()
                                if isParsingReceipt {
                                    ProgressView()
                                }
                            }
                        }
                        Divider()
                        PhotosPicker(selection: $receiptPickerItem, matching: .images, photoLibrary: .shared()) {
                            HStack {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title2)
                                Text("Choose Receipt Photo")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                    // A drop target for dragging a receipt in from Photos or Files,
                    // on top of the scan and picker buttons - iPad's multitasking
                    // makes that a real path to expect, not just a phone affordance.
                    .onDrop(of: [.image], isTargeted: $isTargetingReceiptDrop) { handleReceiptDrop($0) }
                }
            }
            .listRowBackground(isTargetingReceiptDrop ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground))
            
            Section("General Info") {
                DatePicker("Date", selection: $date)
                LocationField(title: "Location", placeholder: "e.g., Costco", text: $locationName) { showingMapPicker = true }
                
                if !locationSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(locationSuggestions, id: \.self) { sug in
                                Button(action: {
                                    locationName = sug.name
                                    latitude = sug.latitude
                                    longitude = sug.longitude
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: sug.isNearby ? "location.fill" : "clock.arrow.circlepath")
                                        Text(sug.name)
                                    }
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                }
                
                FormTextField(title: "Odometer (\(vehicle.odometerUnit.rawValue))", placeholder: "0.0", text: $odometerStr, keyboardType: .decimalPad)
                    .focused($focusedField, equals: .odometer)
            }
            
            if editingFillUp == nil && !isChargeMode {
                Section("Cross Border") {
                    Toggle("Enable Cross Border", isOn: $isCrossBorder)
                    if isCrossBorder {
                        Picker("Foreign Unit", selection: $foreignUnit) {
                            ForEach(FuelUnit.allCases.filter { $0 != .kwh }) { u in Text(u.rawValue).tag(u) }
                        }
                        Picker("Foreign Currency", selection: $foreignCurrency) {
                            ForEach(Currency.allCases) { c in Text(c.rawValue).tag(c) }
                        }
                        FormTextField(title: "Rate (1 \(vehicle.currencyRaw) = X \(foreignCurrency.rawValue))", placeholder: "e.g., 1.35", text: $exchangeRateStr, keyboardType: .decimalPad)
                    }
                }
            }
            
            Section("\(isChargeMode ? "Charge" : "Fuel") Details") {
                let currentUnit = isChargeMode ? FuelUnit.kwh : (isCrossBorder ? foreignUnit : vehicle.fuelUnit)
                let currentCurrency = isCrossBorder ? foreignCurrency : vehicle.currency
                
                FormTextField(title: "Volume (\(currentUnit.rawValue))", placeholder: "0.0", text: $volumeStr, keyboardType: .decimalPad)
                    .focused($focusedField, equals: .volume)
                    .onChange(of: volumeStr) { _, _ in if focusedField == .volume { fieldEdited(.volume) } }
                
                FormTextField(title: "Price / \(currentUnit.rawValue)", placeholder: "0.00", text: $pricePerUnitStr, keyboardType: .decimalPad)
                    .focused($focusedField, equals: .price)
                    .onChange(of: pricePerUnitStr) { _, _ in if focusedField == .price { fieldEdited(.price) } }
                
                FormTextField(title: "Total Cost (\(currentCurrency.rawValue))", placeholder: "0.00", text: $totalCostStr, keyboardType: .decimalPad)
                    .focused($focusedField, equals: .totalCost)
                    .onChange(of: totalCostStr) { _, _ in if focusedField == .totalCost { fieldEdited(.totalCost) } }
                
                if !isChargeMode {
                    let grades = vehicle.fuelType.availableGrades
                    if !grades.isEmpty {
                        Picker("Fuel Grade", selection: $fuelGrade) {
                            Text("Not Recorded").tag(nil as FuelGrade?)
                            ForEach(grades) { grade in
                                Text(grade.rawValue).tag(grade as FuelGrade?)
                            }
                        }
                        if fuelGrade == .other {
                            FormTextField(title: "Grade Name", placeholder: "e.g. Race Fuel", text: $customGradeLabel)
                        }
                    }
                    Toggle("Full Tank", isOn: $isFullTank)
                }
            }
            Section("Notes") { TextEditor(text: $notes).frame(minHeight: 80) }
        }
        .navigationTitle(editingFillUp == nil ? (isChargeMode ? "Log Charge" : "Log Fuel") : "Edit Log").navigationBarTitleDisplayMode(.inline)
        .toolbar { 
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { 
                Button("Save") { saveFillUp() }
                    .disabled((volumeStr.isEmpty ? 0 : 1) + (pricePerUnitStr.isEmpty ? 0 : 1) + (totalCostStr.isEmpty ? 0 : 1) < 2) 
            } 
        }
        .sheet(isPresented: $showingMapPicker) { NavigationStack { LocationPickerView(latitude: $latitude, longitude: $longitude, locationName: $locationName) } }
        .fullScreenCover(isPresented: $isScanningReceipt) {
            DocumentScanner(scannedImage: $scannedImage)
                .ignoresSafeArea()
        }
        .alert("Scanner Unavailable", isPresented: $showingScannerUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Receipt scanning requires a physical device with a camera. It isn't available in the Simulator.")
        }
        .onChange(of: scannedImage) { _, newImage in
            guard let newImage = newImage else { return }
            isParsingReceipt = true
            ReceiptParser.parse(image: newImage, isFuel: true) { t, v, p in
                Task { @MainActor in
                    if let t, totalCostStr.isEmpty { totalCostStr = String(format: "%.2f", t); recentEdits.append(.totalCost) }
                    if let v, volumeStr.isEmpty { volumeStr = String(format: "%.3f", v); recentEdits.append(.volume) }
                    if let p, pricePerUnitStr.isEmpty { pricePerUnitStr = String(format: "%.3f", p); recentEdits.append(.price) }
                    recalculateFields()
                    isParsingReceipt = false
                }
            }
        }
        .onChange(of: receiptPickerItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await MainActor.run { scannedImage = image }
                }
                receiptPickerItem = nil
            }
        }
        .onAppear {
            if let f = editingFillUp { 
                date = f.date
                locationName = f.location?.name ?? ""
                latitude = f.location?.latitude ?? 0
                longitude = f.location?.longitude ?? 0
                if let o = f.odometer { odometerStr = o.odometerString }
                volumeStr = "\(f.volume)"
                pricePerUnitStr = "\(f.pricePerUnit)"
                totalCostStr = String(format: "%.2f", f.volume * f.pricePerUnit)
                isFullTank = f.isFullTank
                fuelGrade = f.fuelGrade
                customGradeLabel = f.customGradeLabel ?? ""
                notes = f.notes
                if let rData = f.receiptData { scannedImage = UIImage(data: rData) }
            } else {
                if let lastOdo = vehicle.lastOdometer {
                    odometerStr = lastOdo.odometerString
                }
                // Preselect the vehicle's configured grade; for flex-fuel (which
                // has no configured default) fall back to the last grade used.
                fuelGrade = vehicle.defaultGradeRaw.flatMap { FuelGrade(rawValue: $0) }
                    ?? (vehicle.fillUps ?? [])
                        .sorted { $0.date > $1.date }
                        .compactMap(\.fuelGrade)
                        .first
                    ?? vehicle.fuelType.defaultGrade
                if fuelGrade == .other { customGradeLabel = vehicle.customGradeLabel ?? "" }
                foreignUnit = vehicle.fuelUnit == .gallons ? .liters : .gallons
                foreignCurrency = vehicle.currency == .usd ? .cad : .usd
                exchangeRateStr = "\(lastExchangeRate)"
            }
            
            locationManager.onLocationUpdate = { loc in
                if isChargeMode {
                    searchNearbyChargers(center: loc.coordinate)
                } else {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = "Gas Station"
                    request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
                    MKLocalSearch(request: request).start { response, _ in
                        if let items = response?.mapItems {
                            DispatchQueue.main.async {
                                self.nearbyLocations = items.compactMap { item in
                                    guard let name = item.name else { return nil }
                                    return LocationSuggestion(name: name, latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude, isNearby: true)
                                }
                            }
                        }
                    }
                }
            }
            locationManager.requestLocation()
        }
        .onDisappear {
            endLiveActivity()
        }
    }
    
    private func fieldEdited(_ field: FillUpFocus) {
        if recentEdits.last != field {
            recentEdits.removeAll { $0 == field }
            recentEdits.append(field)
        }
        recalculateFields()
    }
    
    /// Accepts an image dragged in from Photos, Files, or another app's window.
    /// Loading is async since NSItemProvider always is, but the drop itself is
    /// accepted synchronously so the drag doesn't visually bounce back.
    private func handleReceiptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: UIImage.self) else { return false }
        _ = provider.loadObject(ofClass: UIImage.self) { image, _ in
            guard let uiImage = image as? UIImage else { return }
            DispatchQueue.main.async { scannedImage = uiImage }
        }
        return true
    }

    private func recalculateFields() {
        let volStr = volumeStr.replacingOccurrences(of: ",", with: ".")
        let pStr = pricePerUnitStr.replacingOccurrences(of: ",", with: ".")
        let tStr = totalCostStr.replacingOccurrences(of: ",", with: ".")
        
        let vol = Double(volStr)
        let price = Double(pStr)
        let total = Double(tStr)
        
        var fixedField: FillUpFocus? = nil
        var changingField: FillUpFocus? = nil
        
        if recentEdits.count >= 2 {
            changingField = recentEdits[recentEdits.count - 1]
            fixedField = recentEdits[recentEdits.count - 2]
        } else if recentEdits.count == 1 {
            changingField = recentEdits[0]
            if changingField == .totalCost {
                if price != nil && price! > 0 { fixedField = .price }
                else if vol != nil && vol! > 0 { fixedField = .volume }
            } else if changingField == .volume {
                if price != nil && price! > 0 { fixedField = .price }
                else if total != nil && total! > 0 { fixedField = .totalCost }
            } else if changingField == .price {
                if vol != nil && vol! > 0 { fixedField = .volume }
                else if total != nil && total! > 0 { fixedField = .totalCost }
            }
        }
        
        guard let changing = changingField, let fixed = fixedField else { return }
        
        let targetField: FillUpFocus
        let fields: Set<FillUpFocus> = [.volume, .price, .totalCost]
        targetField = fields.subtracting([changing, fixed]).first!
        
        switch targetField {
        case .volume:
            if let t = total, let p = price, p > 0 {
                volumeStr = formatNumber(t / p)
            } else if (changing == .totalCost && total == nil) || (changing == .price && price == nil) {
                volumeStr = ""
            }
        case .price:
            if let t = total, let v = vol, v > 0 {
                pricePerUnitStr = formatNumber(t / v)
            } else if (changing == .totalCost && total == nil) || (changing == .volume && vol == nil) {
                pricePerUnitStr = ""
            }
        case .totalCost:
            if let v = vol, let p = price {
                totalCostStr = formatNumber(v * p, isCurrency: true)
            } else if (changing == .volume && vol == nil) || (changing == .price && price == nil) {
                totalCostStr = ""
            }
        default: break
        }

        syncLiveActivity()
    }

    private func syncLiveActivity() {
        guard liveActivityEnabled else {
            if liveActivity != nil {
                endLiveActivity()
            }
            return
        }
        let vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let price = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let total = Double(totalCostStr.replacingOccurrences(of: ",", with: ".")) ?? 0

        guard vol > 0 || price > 0 || total > 0 else { return }

        let unitRaw = isChargeMode ? FuelUnit.kwh.rawValue : vehicle.fuelUnitRaw

        if liveActivity == nil {
            liveActivity = FuelFillUpActivityManager.start(vehicleName: vehicle.name, unitRaw: unitRaw, currencyRaw: vehicle.currencyRaw)
        }
        if let activity = liveActivity {
            FuelFillUpActivityManager.update(activity, volume: vol, pricePerUnit: price, totalCost: total)
        }
    }

    private func endLiveActivity() {
        let vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let price = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let total = Double(totalCostStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        FuelFillUpActivityManager.end(liveActivity, volume: vol, pricePerUnit: price, totalCost: total)
        liveActivity = nil
    }
    
    private func formatNumber(_ num: Double, isCurrency: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = isCurrency ? 2 : 3
        return formatter.string(from: NSNumber(value: num)) ?? ""
    }
    
    private func saveFillUp() {
        var vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        var ppu = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        var tc = Double(totalCostStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        let exRate = Double(exchangeRateStr.replacingOccurrences(of: ",", with: ".")) ?? 1.0
        
        // Derive the missing value if the user didn't enter all three.
        if tc > 0 {
            if vol > 0 && ppu == 0 { ppu = tc / vol }
            else if ppu > 0 && vol == 0 { vol = tc / ppu }
        }
        if tc == 0 && vol > 0 && ppu > 0 { tc = vol * ppu }
        
        var finalVol = vol
        var finalPPU = ppu
        var appendedNotes = ""
        
        // If cross border is on, we gracefully convert it down to the vehicle's native units
        // so none of the statistics engines require complex rewriting.
        if isCrossBorder {
            let safeRate = exRate > 0 ? exRate : 1.0
            lastExchangeRate = safeRate
            
            let nativeVol: Double
            if foreignUnit == vehicle.fuelUnit {
                nativeVol = vol
            } else if vehicle.fuelUnit == .gallons && foreignUnit == .liters {
                nativeVol = vol * 0.264172
            } else if vehicle.fuelUnit == .liters && foreignUnit == .gallons {
                nativeVol = vol * 3.78541
            } else {
                nativeVol = vol
            }
            
            let nativeTC = tc / safeRate
            let nativePPU = nativeVol > 0 ? (nativeTC / nativeVol) : 0
            
            appendedNotes = (notes.isEmpty ? "" : "\n\n") + "🌍 Cross Border Log:\n• \(vol.formatted()) \(foreignUnit.rawValue)\n• \(tc.formatted(.currency(code: foreignCurrency.rawValue)))\n• Exchange Rate: \(exRate)"
            
            finalVol = nativeVol
            finalPPU = nativePPU
        }
        
        let odo = Double(odometerStr.replacingOccurrences(of: ",", with: ".")), finalLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNotes = isCrossBorder ? (notes + appendedNotes) : notes
        let finalReceiptData = scannedImage?.jpegData(compressionQuality: 0.7)
        
        // Charging has no fuel grade.
        let finalGrade: FuelGrade? = isChargeMode ? nil : fuelGrade
        let trimmedGradeLabel = customGradeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalGradeLabel: String? = (finalGrade == .other && !trimmedGradeLabel.isEmpty) ? trimmedGradeLabel : nil

        if let f = editingFillUp {
            f.date = date; f.odometer = odo; f.volume = finalVol; f.pricePerUnit = finalPPU; f.isFullTank = isChargeMode ? true : isFullTank; f.notes = finalNotes; f.receiptData = finalReceiptData
            f.fuelGrade = finalGrade
            f.customGradeLabel = finalGradeLabel
            // Point this fill-up at the right station rather than editing the
            // station itself. GasLocation is shared by every log that used it, so
            // renaming it in place renamed all of them - log Costco then Chevron,
            // and both rows read Chevron.
            f.location = resolveLocation(named: finalLocationName, latitude: latitude, longitude: longitude)
        } else {
            let newLoc = resolveLocation(named: finalLocationName, latitude: latitude, longitude: longitude)
            let newFillUp = FillUp(date: date, odometer: odo, volume: finalVol, pricePerUnit: finalPPU, isFullTank: isChargeMode ? true : isFullTank, notes: finalNotes, unit: isChargeMode ? .kwh : vehicle.fuelUnit, grade: finalGrade, vehicle: vehicle, location: newLoc, receiptData: finalReceiptData)
            newFillUp.customGradeLabel = finalGradeLabel
            modelContext.insert(newFillUp)
            if vehicle.fillUps == nil { vehicle.fillUps = [] }
            vehicle.fillUps?.append(newFillUp)
        }
        
        // Force UI update
        let temp = vehicle.fuelUnitRaw
        vehicle.fuelUnitRaw = ""
        vehicle.fuelUnitRaw = temp
        
        try? modelContext.save()
        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: vehicle)
        }
        endLiveActivity()
        dismiss()
    }
    
    private func resolveLocation(named name: String, latitude: Double, longitude: Double) -> GasLocation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || latitude != 0 else { return nil }
        let (lat, lon) = coordinatesForSaving(latitude: latitude, longitude: longitude)
        let candidates = (try? modelContext.fetch(FetchDescriptor<GasLocation>())) ?? []
        if let existing = GasLocation.matching(name: trimmed, latitude: lat, longitude: lon, in: candidates) { return existing }
        let loc = GasLocation(name: trimmed, latitude: lat, longitude: lon)
        modelContext.insert(loc)
        return loc
    }

    /// Coordinates are only captured when a suggestion is tapped, so a station
    /// name typed by hand was stored at 0,0 and never drew a pin. Falls back to
    /// where the device is now.
    ///
    /// Only for a log dated today: backdating an entry and typing a name would
    /// otherwise pin it wherever the user happens to be, which is worse than no
    /// pin at all. An explicitly chosen suggestion always wins.
    private func coordinatesForSaving(latitude: Double, longitude: Double) -> (Double, Double) {
        guard latitude == 0, longitude == 0,
              Calendar.current.isDateInToday(date),
              let here = locationManager.location else { return (latitude, longitude) }
        return (here.coordinate.latitude, here.coordinate.longitude)
    }
    
    private func searchNearbyChargers(center: CLLocationCoordinate2D) {
        let isTesla = vehicle.make.localizedLowercase.contains("tesla")
        let queries: [String] = isTesla
            ? ["Tesla Supercharger", "EVgo", "Electrify America", "EV Fast Charger"]
            : ["EVgo", "Electrify America", "Tesla Supercharger", "EV Fast Charger"]
        searchNearby(queries: queries, center: center, pointOfInterestFilter: MKPointOfInterestFilter(including: [.evCharger]))
    }

    private func searchNearby(queries: [String], center: CLLocationCoordinate2D, pointOfInterestFilter: MKPointOfInterestFilter? = nil) {
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 5000, longitudinalMeters: 5000)
        let lock = NSLock()
        var results: [LocationSuggestion] = []
        var seen = Set<String>()
        let group = DispatchGroup()
        
        for query in queries {
            group.enter()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = region
            if let pointOfInterestFilter {
                request.pointOfInterestFilter = pointOfInterestFilter
            }
            MKLocalSearch(request: request).start { response, _ in
                defer { group.leave() }
                guard let items = response?.mapItems else { return }
                for item in items {
                    guard let name = item.name else { continue }
                    lock.lock()
                    defer { lock.unlock() }
                    if seen.insert(name.localizedLowercase).inserted {
                        results.append(LocationSuggestion(name: name, latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude, isNearby: true))
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            self.nearbyLocations = results
        }
    }
}
