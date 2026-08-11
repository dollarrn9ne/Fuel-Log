import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import PhotosUI
import FuelLogShared

struct AddServiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var previousLocations: [GasLocation]
    
    let vehicle: Vehicle
    var editingService: ServiceRecord?
    
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var nearbyLocations: [LocationSuggestion] = []
    
    @State private var date: Date = .now
    @State private var locationName: String = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var showingMapPicker = false
    
    @State private var odometerStr: String = ""
    @State private var type: ServiceType = .general
    @State private var costStr: String = ""
    @State private var notes: String = ""
    
    // Receipt Scanning
    @State private var scannedImage: UIImage?
    @State private var isScanningReceipt = false
    @State private var isParsingReceipt = false
    @State private var showingScannerUnavailableAlert = false

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
                } else {
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
                }
            }
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            
            Section("Service Details") {
                DatePicker("Date", selection: $date)
                LocationField(title: "Location", placeholder: "e.g., Jiffy Lube", text: $locationName) { showingMapPicker = true }
                
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
                Picker("Service Type", selection: $type) { ForEach(ServiceType.allCases) { t in Text(t.rawValue).tag(t) } }
                FormTextField(title: "Total Cost", placeholder: "0.00", text: $costStr, keyboardType: .decimalPad)
            }
            Section("Notes & Description") { TextEditor(text: $notes).frame(minHeight: 80) }
        }
        .navigationTitle(editingService == nil ? "Log Service" : "Edit Service").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { saveService() }.disabled(odometerStr.isEmpty || costStr.isEmpty) } }
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
            ReceiptParser.parse(image: newImage, isFuel: false) { t, _, _ in
                Task { @MainActor in
                    if let t, costStr.isEmpty { costStr = String(format: "%.2f", t) }
                    isParsingReceipt = false
                }
            }
        }
        .onAppear { 
            if let s = editingService { 
                date = s.date; locationName = s.location?.name ?? ""; latitude = s.location?.latitude ?? 0; longitude = s.location?.longitude ?? 0; odometerStr = s.odometer.odometerString; type = s.type; costStr = "\(s.cost)"; notes = s.notes
                if let rData = s.receiptData { scannedImage = UIImage(data: rData) }
            } else if let lastOdo = vehicle.lastOdometer { 
                odometerStr = lastOdo.odometerString 
            } 
            
            locationManager.onLocationUpdate = { loc in
                self.searchNearbyServices(center: loc.coordinate)
            }
            locationManager.requestLocation()
        }
    }
    
    private func saveService() {
        let odo = Double(odometerStr.replacingOccurrences(of: ",", with: ".")) ?? 0, cost = Double(costStr.replacingOccurrences(of: ",", with: ".")) ?? 0, finalLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalReceiptData = scannedImage?.jpegData(compressionQuality: 0.7)
        
        if let s = editingService {
            s.date = date; s.odometer = odo; s.type = type; s.cost = cost; s.notes = notes; s.receiptData = finalReceiptData
            if let existingLoc = s.location { existingLoc.name = finalLocationName; existingLoc.latitude = latitude; existingLoc.longitude = longitude } else { s.location = resolveLocation(named: finalLocationName, latitude: latitude, longitude: longitude) }
        } else {
            let newLoc = resolveLocation(named: finalLocationName, latitude: latitude, longitude: longitude)
            let newService = ServiceRecord(date: date, odometer: odo, type: type, cost: cost, notes: notes, vehicle: vehicle, location: newLoc, receiptData: finalReceiptData)
            modelContext.insert(newService)
            if vehicle.services == nil { vehicle.services = [] }
            vehicle.services?.append(newService)
        }
        
        // Force UI update
        let temp = vehicle.fuelUnitRaw
        vehicle.fuelUnitRaw = ""
        vehicle.fuelUnitRaw = temp
        
        try? modelContext.save()
        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: vehicle)
        }
        dismiss()
    }
    
    private func searchNearbyServices(center: CLLocationCoordinate2D) {
        let queries = ["AAA", "Walmart Auto Care Center", "America's Tire", "Auto Repair", "Tire Shop", "Oil Change"]
        searchNearby(queries: queries, center: center)
    }

    private func searchNearby(queries: [String], center: CLLocationCoordinate2D) {
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

    private func resolveLocation(named name: String, latitude: Double, longitude: Double) -> GasLocation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || latitude != 0 else { return nil }
        let existing = (try? modelContext.fetch(FetchDescriptor<GasLocation>()))?.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        if let existing { return existing }
        let loc = GasLocation(name: trimmed, latitude: latitude, longitude: longitude)
        modelContext.insert(loc)
        return loc
    }
}
