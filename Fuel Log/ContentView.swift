//
//  ContentView.swift
//  Fuel Log
//
//  Created by Denis Yeremuk on 3/12/26.
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation
import MapKit
import PhotosUI
import UniformTypeIdentifiers
import Combine
import UIKit

// MARK: - Enums
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum FuelUnit: String, Codable, CaseIterable, Identifiable {
    case gallons = "Gallons"
    case liters = "Liters"
    var id: String { rawValue }
}

enum OdometerUnit: String, Codable, CaseIterable, Identifiable {
    case miles = "Miles"
    case kilometers = "Kilometers"
    var id: String { rawValue }
}

enum EfficiencyUnit: String, Codable, CaseIterable, Identifiable {
    case mpgUS = "MPG (US)"
    case mpgUK = "MPG (UK)"
    case l100km = "L/100 km"
    case kmPerLitre = "km/L"
    var id: String { rawValue }
}

enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case oilChange = "Oil Change", tires = "Tires", brakes = "Brakes", battery = "Battery", general = "General"
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .oilChange: return "drop.fill"
        case .tires: return "dot.circle"
        case .brakes: return "exclamationmark.circle"
        case .battery: return "battery.100"
        case .general: return "wrench.adjustable"
        }
    }
    
    var color: Color {
        switch self {
        case .oilChange: return .orange
        case .tires: return .gray
        case .brakes: return .red
        case .battery: return .green
        case .general: return .blue
        }
    }
}

enum ExportEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case ascii = "ASCII"
    case windows1252 = "Windows-1252"
    case isoLatin1 = "ISO Latin 1"
    case isoLatin2 = "ISO Latin 2"
    case utf16 = "UTF-16"
    case utf32 = "UTF-32"
    case shiftJIS = "Shift JIS"
    case macRoman = "Mac OS Roman"
    case japaneseEUC = "Japanese (EUC)"
    
    var id: String { rawValue }
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .ascii: return .ascii
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        case .isoLatin2: return .isoLatin2
        case .utf16: return .utf16
        case .utf32: return .utf32
        case .shiftJIS: return .shiftJIS
        case .macRoman: return .macOSRoman
        case .japaneseEUC: return .japaneseEUC
        }
    }
}

enum ImportSource: String, CaseIterable, Identifiable {
    case roadTrip = "Road Trip"
    case fuelly = "Fuelly"
    case mileIQ = "MileIQ"
    case fuelio = "Fuelio"
    case pelican = "Pelican"
    case none = "None (Native)"
    
    var id: String { rawValue }
}

// MARK: - CSV Document
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    var encoding: String.Encoding
    
    init(text: String, encoding: String.Encoding = .utf8) {
        self.text = text
        self.encoding = encoding
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else { text = "" }
        self.encoding = .utf8
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: encoding) ?? text.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

// MARK: - Models
@Model final class Vehicle {
    var id: UUID
    var name: String
    var make: String
    var model: String
    var year: Int?
    
    @Attribute(.externalStorage) var photoData: Data?
    
    var odometerUnit: OdometerUnit
    var fuelUnit: FuelUnit
    var efficiencyUnit: EfficiencyUnit
    var maintenanceInterval: Double = 5000.0
    
    var purchaseDate: Date?
    var purchasePrice: Double?
    var currentValue: Double?
    var isArchived: Bool = false
    
    @Relationship(deleteRule: .cascade, inverse: \FillUp.vehicle) var fillUps: [FillUp] = []
    @Relationship(deleteRule: .cascade, inverse: \ServiceRecord.vehicle) var services: [ServiceRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \Trip.vehicle) var trips: [Trip] = []

    init(id: UUID = UUID(), name: String, make: String = "", model: String = "", year: Int? = nil, odometerUnit: OdometerUnit = .miles, fuelUnit: FuelUnit = .gallons, efficiencyUnit: EfficiencyUnit = .mpgUS) {
        self.id = id; self.name = name; self.make = make; self.model = model; self.year = year; self.odometerUnit = odometerUnit; self.fuelUnit = fuelUnit; self.efficiencyUnit = efficiencyUnit
    }

    var averageEfficiency: Double? {
        let sorted = fillUps.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        var dist: Double = 0, vol: Double = 0
        for (prev, curr) in zip(sorted, sorted.dropFirst()) {
            guard let cOdo = curr.odometer, let pOdo = prev.odometer, cOdo > pOdo, curr.isFullTank else { continue }
            dist += (cOdo - pOdo)
            vol += curr.volume
        }
        guard vol > 0, dist > 0 else { return nil }
        return efficiencyUnit == .l100km ? (vol / dist) * 100.0 : (dist / vol)
    }

    var totalCost: Double { totalFuelCost + totalServiceCost }
    var totalFuelCost: Double { fillUps.map(\.totalCost).reduce(0, +) }
    var totalServiceCost: Double { services.map(\.cost).reduce(0, +) }
    
    var totalDistanceLogged: Double {
        let odos = (fillUps.compactMap(\.odometer) + services.compactMap(\.odometer))
        guard let minOdo = odos.min(), let maxOdo = odos.max(), maxOdo > minOdo else { return 0 }
        return maxOdo - minOdo
    }
    
    var lastOdometer: Double? { fillUps.compactMap(\.odometer).max() ?? services.compactMap(\.odometer).max() }
    
    var isMaintenanceDue: Bool {
        guard let current = lastOdometer, let lastService = services.filter({ $0.type == .oilChange }).map(\.odometer).max() else { return true }
        return (current - lastService) >= maintenanceInterval
    }
}

@Model final class FillUp {
    var id: UUID
    var date: Date
    var odometer: Double?
    var volume: Double
    var pricePerUnit: Double
    var isFullTank: Bool
    var notes: String
    var unit: FuelUnit
    var vehicle: Vehicle?
    var location: GasLocation?

    init(id: UUID = UUID(), date: Date = .now, odometer: Double? = nil, volume: Double, pricePerUnit: Double, isFullTank: Bool = true, notes: String = "", unit: FuelUnit = .gallons, vehicle: Vehicle? = nil, location: GasLocation? = nil) {
        self.id = id; self.date = date; self.odometer = odometer; self.volume = volume; self.pricePerUnit = pricePerUnit; self.isFullTank = isFullTank; self.notes = notes; self.unit = unit; self.vehicle = vehicle; self.location = location
    }
    var totalCost: Double { volume * pricePerUnit }
}

@Model final class ServiceRecord {
    var id: UUID
    var date: Date
    var odometer: Double
    var type: ServiceType
    var cost: Double
    var notes: String
    var vehicle: Vehicle?
    var location: GasLocation?

    init(id: UUID = UUID(), date: Date = .now, odometer: Double, type: ServiceType, cost: Double, notes: String = "", vehicle: Vehicle? = nil, location: GasLocation? = nil) {
        self.id = id; self.date = date; self.odometer = odometer; self.type = type; self.cost = cost; self.notes = notes; self.vehicle = vehicle; self.location = location
    }
}

@Model final class GasLocation {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude
    }
}

@Model final class TripCategory {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .nullify, inverse: \Trip.category) var trips: [Trip] = []
    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

@Model final class Trip {
    var id: UUID
    var name: String
    var startDate: Date
    var endDate: Date
    var startOdometer: Double?
    var endOdometer: Double?
    var category: TripCategory?
    var vehicle: Vehicle?
    
    var distance: Double? {
        guard let s = startOdometer, let e = endOdometer, e >= s else { return nil }
        return e - s
    }
    
    init(id: UUID = UUID(), name: String, startDate: Date = .now, endDate: Date = .now, startOdometer: Double? = nil, endOdometer: Double? = nil, category: TripCategory? = nil, vehicle: Vehicle? = nil) {
        self.id = id; self.name = name; self.startDate = startDate; self.endDate = endDate; self.startOdometer = startOdometer; self.endOdometer = endOdometer; self.category = category; self.vehicle = vehicle
    }
}

// MARK: - Reusable UI Components
struct FormTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboardType)
        }
    }
}

struct LocationField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onMapTap: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
            Button(action: onMapTap) {
                Image(systemName: "map.fill").foregroundColor(.accentColor)
            }
        }
    }
}

struct ProgressOverlay: View {
    let title: String
    let progress: Double
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(title).font(.headline)
                ProgressView(value: progress, total: 1.0).progressViewStyle(.linear)
                Text("\(Int(progress * 100))%").font(.subheadline)
            }
            .padding(24)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(16)
            .padding(40)
        }
    }
}

struct SelectedEventCard: View {
    let event: VehicleEvent
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: event.icon).foregroundStyle(event.color)
                Text(event.title).font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundColor(.secondary)
            }
            HStack {
                Text(event.date, style: .date)
                Spacer()
                Text(event.cost, format: .currency(code: "USD")).fontWeight(.bold)
            }
            .font(.body).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - CSV Importer
@MainActor
class CSVImporter: ObservableObject {
    @Published var isImporting = false
    @Published var importProgress: Double = 0.0

    func performImport(data: String, source: ImportSource, modelContext: ModelContext) async {
        isImporting = true
        importProgress = 0.0
        
        let rows = parseCSV(data)
        guard !rows.isEmpty else { isImporting = false; return }
        
        switch source {
        case .roadTrip:
            await importRoadTripCSV(rows, modelContext: modelContext)
        case .none:
            if rows.first?.first == "Vehicle" {
                await importNativeCSV(rows, modelContext: modelContext)
            } else if data.contains("ROAD TRIP CSV") || rows.first?.first?.contains("ROAD TRIP CSV") == true {
                await importRoadTripCSV(rows, modelContext: modelContext)
            } else {
                await importNativeCSV(rows, modelContext: modelContext)
            }
        case .fuelly, .mileIQ, .fuelio, .pelican:
            await importNativeCSV(rows, modelContext: modelContext)
        }
        
        isImporting = false
    }
    
    private func parseFlexibleDate(_ dateStr: String) -> Date? {
        let formatter = DateFormatter()
        let formats = ["yyyy-M-d H:mm", "yyyy-MM-dd HH:mm", "yyyy-M-d", "yyyy-MM-dd", "MM/dd/yy", "M/d/yy H:mm", "MM/dd/yy HH:mm"]
        for format in formats {
            formatter.dateFormat = format
            if let d = formatter.date(from: dateStr) { return d }
        }
        return nil
    }

    private func importNativeCSV(_ rows: [[String]], modelContext: ModelContext) async {
        guard rows.count > 1 else { return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short; dateFormatter.timeStyle = .short
        
        var existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        let totalRows = Double(rows.count - 1)
        
        for (index, row) in rows.dropFirst().enumerated() {
            if index % 20 == 0 { importProgress = Double(index) / totalRows; try? await Task.sleep(nanoseconds: 10_000_000) }
            guard row.count >= 8 else { continue }
            
            let vehicleName = row[0], recordType = row[1], dateStr = row[2], odoStr = row[3]
            let costStr = row[4], detailsStr = row[5], locStr = row[6], notesStr = row[7]
            
            let vehicle: Vehicle
            if let existing = existingVehicles.first(where: { $0.name == vehicleName }) {
                vehicle = existing
            } else {
                vehicle = Vehicle(name: vehicleName)
                modelContext.insert(vehicle)
                existingVehicles.append(vehicle)
                modelContext.insert(Trip(name: "Since Day One - \(vehicleName)", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
            }
            
            let date = dateFormatter.date(from: dateStr) ?? Date()
            let odo = Double(odoStr)
            let cost = Double(costStr) ?? 0
            let loc = locStr.isEmpty ? nil : GasLocation(name: locStr, latitude: 0, longitude: 0)
            
            if recordType == "Fuel" {
                let components = detailsStr.components(separatedBy: " ")
                let vol = components.first.flatMap { Double($0) } ?? 0
                let unit = FuelUnit(rawValue: components.dropFirst().joined(separator: " ")) ?? .gallons
                let pricePerUnit = vol > 0 ? (cost / vol) : 0
                
                if !vehicle.fillUps.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(FillUp(date: date, odometer: odo, volume: vol, pricePerUnit: pricePerUnit, isFullTank: true, notes: notesStr, unit: unit, vehicle: vehicle, location: loc))
                }
            } else if recordType == "Service" {
                let type = ServiceType(rawValue: detailsStr) ?? .general
                if !vehicle.services.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.type == type }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(ServiceRecord(date: date, odometer: odo ?? 0, type: type, cost: cost, notes: notesStr, vehicle: vehicle, location: loc))
                }
            }
        }
        try? modelContext.save()
    }
    
    private func importRoadTripCSV(_ rows: [[String]], modelContext: ModelContext) async {
        var vehicleName = "Imported Vehicle"
        for (i, row) in rows.enumerated() {
            if row.first == "VEHICLE" && i + 2 < rows.count { vehicleName = rows[i+2].first ?? "Imported Vehicle"; break }
        }
        
        var existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        let vehicle: Vehicle
        if let existing = existingVehicles.first(where: { $0.name == vehicleName }) {
            vehicle = existing
        } else {
            vehicle = Vehicle(name: vehicleName)
            modelContext.insert(vehicle)
            existingVehicles.append(vehicle)
            modelContext.insert(Trip(name: "Since Day One - \(vehicleName)", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
        }
        
        var currentSection = ""
        let existingCategories = (try? modelContext.fetch(FetchDescriptor<TripCategory>())) ?? []
        var categoryMap = Dictionary(uniqueKeysWithValues: existingCategories.map { ($0.name, $0) })
        
        let totalRows = Double(rows.count)
        
        for i in 0..<rows.count {
            if i % 20 == 0 { importProgress = Double(i) / totalRows; try? await Task.sleep(nanoseconds: 10_000_000) }
            
            let row = rows[i]
            guard !row.isEmpty else { continue }
            
            let first = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if ["FUEL RECORDS", "MAINTENANCE RECORDS", "ROAD TRIPS", "VEHICLE", "TIRE LOG", "VALUATIONS"].contains(first) {
                if first == "FUEL RECORDS" { currentSection = "FUEL" }
                else if first == "MAINTENANCE RECORDS" { currentSection = "MAINT" }
                else if first == "ROAD TRIPS" { currentSection = "TRIPS" }
                else { currentSection = "OTHER" }
                continue
            }
            if ["Odometer (mi)", "Description", "Name"].contains(first) { continue }
            
            if currentSection == "FUEL", row.count >= 7 {
                let vol = Double(row[3]) ?? 0
                let date = parseFlexibleDate(row[2]) ?? Date()
                let locStr = row.count > 11 ? row[11] : ""
                let loc = locStr.isEmpty ? nil : GasLocation(name: locStr, latitude: Double(row.count > 19 ? row[19] : "") ?? 0, longitude: Double(row.count > 20 ? row[20] : "") ?? 0)
                
                if !vehicle.fillUps.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(FillUp(date: date, odometer: Double(row[0]), volume: vol, pricePerUnit: Double(row[5]) ?? 0, isFullTank: (row.count > 7 ? row[7] : "") != "Partial", notes: row.count > 9 ? row[9] : "", unit: vehicle.fuelUnit, vehicle: vehicle, location: loc))
                }
            } else if currentSection == "MAINT", row.count >= 6 {
                let cost = Double(row[3]) ?? 0
                let date = parseFlexibleDate(row[1]) ?? Date()
                let locStr = row[5]
                let loc = locStr.isEmpty ? nil : GasLocation(name: locStr, latitude: Double(row.count > 15 ? row[15] : "") ?? 0, longitude: Double(row.count > 16 ? row[16] : "") ?? 0)
                
                let lowerDesc = row[0].lowercased()
                let type: ServiceType = lowerDesc.contains("oil") ? .oilChange : (lowerDesc.contains("tire") || lowerDesc.contains("rotation") ? .tires : (lowerDesc.contains("brake") ? .brakes : (lowerDesc.contains("battery") ? .battery : .general)))
                let finalNote = row[4].isEmpty ? row[0] : "\(row[0]) - \(row[4])"
                
                if !vehicle.services.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.type == type && $0.cost == cost }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(ServiceRecord(date: date, odometer: Double(row[2]) ?? 0, type: type, cost: cost, notes: finalNote, vehicle: vehicle, location: loc))
                }
            } else if currentSection == "TRIPS", row.count >= 5 {
                let startDate = parseFlexibleDate(row[1]) ?? Date()
                let catName = row.count > 9 ? row[9] : ""
                var category: TripCategory? = nil
                
                if !catName.isEmpty {
                    if let existing = categoryMap[catName] { category = existing } else {
                        let newCat = TripCategory(name: catName)
                        modelContext.insert(newCat); categoryMap[catName] = newCat; category = newCat
                    }
                }
                
                let allTrips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []
                if !allTrips.contains(where: { $0.name == row[0] && abs($0.startDate.timeIntervalSince(startDate)) < 86400 }) {
                    modelContext.insert(Trip(name: row[0], startDate: startDate, endDate: parseFlexibleDate(row[3]) ?? startDate, startOdometer: Double(row[2]), endOdometer: Double(row[4]), category: category, vehicle: vehicle))
                }
            }
        }
        try? modelContext.save()
    }
    
    private func parseCSV(_ data: String) -> [[String]] {
        var result: [[String]] = [], currentRow: [String] = [], currentField = "", insideQuotes = false
        let characters = Array(data)
        var i = 0
        
        while i < characters.count {
            let char = characters[i]
            if char == "\"" {
                if insideQuotes, i + 1 < characters.count, characters[i + 1] == "\"" { currentField.append("\""); i += 1 } else { insideQuotes.toggle() }
            } else if char == ",", !insideQuotes {
                currentRow.append(currentField); currentField = ""
            } else if (char == "\n" || char == "\r"), !insideQuotes {
                if char == "\r", i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }
                currentRow.append(currentField); result.append(currentRow); currentRow = []; currentField = ""
            } else { currentField.append(char) }
            i += 1
        }
        if !currentRow.isEmpty || !currentField.isEmpty { currentRow.append(currentField); result.append(currentRow) }
        return result
    }
}

// MARK: - App Logo
struct AppLogoIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.0, blue: 0.2), Color(red: 0.2, green: 0.0, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                ZStack {
                    Circle().fill(LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .top, endPoint: .bottom)).frame(width: w * 0.6).shadow(color: .pink.opacity(0.8), radius: w * 0.05)
                    VStack(spacing: w * 0.012) {
                        Spacer()
                        Rectangle().fill(Color(red: 0.12, green: 0.0, blue: 0.28)).frame(height: w * 0.005)
                        Rectangle().fill(Color(red: 0.13, green: 0.0, blue: 0.30)).frame(height: w * 0.01)
                        Rectangle().fill(Color(red: 0.14, green: 0.0, blue: 0.32)).frame(height: w * 0.015)
                        Rectangle().fill(Color(red: 0.15, green: 0.0, blue: 0.35)).frame(height: w * 0.02)
                        Rectangle().fill(Color(red: 0.16, green: 0.0, blue: 0.38)).frame(height: w * 0.03)
                    }.frame(width: w * 0.65, height: w * 0.6)
                    Image(systemName: "fuelpump.fill").resizable().aspectRatio(contentMode: .fit).frame(height: w * 0.38).foregroundStyle(Color(red: 0.05, green: 0.0, blue: 0.1)).offset(x: w * 0.035, y: w * 0.01)
                }.position(x: w * 0.5, y: w * 0.35)
                Rectangle().fill(Color(red: 0.05, green: 0.0, blue: 0.1)).frame(width: w, height: w * 0.5).position(x: w * 0.5, y: w * 0.8)
                Rectangle().fill(LinearGradient(colors: [.clear, .pink.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)).frame(width: w, height: w * 0.02).blur(radius: w * 0.01).position(x: w * 0.5, y: w * 0.55)
                Path { p in p.move(to: CGPoint(x: w * 0.46, y: w * 0.55)); p.addLine(to: CGPoint(x: w * 0.54, y: w * 0.55)); p.addLine(to: CGPoint(x: w * 0.85, y: w)); p.addLine(to: CGPoint(x: w * 0.15, y: w)); p.closeSubpath() }.fill(Color(white: 0.02))
                Path { p in p.move(to: CGPoint(x: w * 0.46, y: w * 0.55)); p.addLine(to: CGPoint(x: w * 0.15, y: w)); p.move(to: CGPoint(x: w * 0.54, y: w * 0.55)); p.addLine(to: CGPoint(x: w * 0.85, y: w)) }.stroke(Color.cyan, lineWidth: w * 0.015).shadow(color: .cyan, radius: w * 0.02)
                Path { p in p.move(to: CGPoint(x: w * 0.5, y: w * 0.55)); p.addLine(to: CGPoint(x: w * 0.5, y: w)) }.stroke(Color.yellow, style: StrokeStyle(lineWidth: w * 0.015, dash: [w * 0.06, w * 0.04])).shadow(color: .yellow, radius: w * 0.02)
                RoundedRectangle(cornerRadius: w * 0.22, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, w * 0.01))
            }.clipShape(RoundedRectangle(cornerRadius: w * 0.22, style: .continuous))
        }.aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Splash Screen
struct SplashScreenView: View {
    @Binding var hasSeenSplash: Bool
    @State private var currentStep = 0
    @StateObject private var locationManager = CurrentLocationManager()

    var body: some View {
        ZStack {
            if currentStep == 0 {
                welcomeView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                locationView
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: currentStep)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
    
    private var welcomeView: some View {
        VStack {
            Spacer()
            AppLogoIcon()
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 8)
                .padding(.bottom, 24)
            Text("Welcome to\nFuel Log")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)
            VStack(alignment: .leading, spacing: 32) {
                FeatureRow(icon: "fuelpump.fill", color: .blue, title: "Track Fuel & Efficiency", description: "Easily log your fill-ups and monitor your vehicle's fuel efficiency over time.")
                FeatureRow(icon: "wrench.and.screwdriver.fill", color: .orange, title: "Maintenance Logs", description: "Keep a detailed history of services.")
                FeatureRow(icon: "map.fill", color: .green, title: "Trip Tracking", description: "Record trips, categorize them, and calculate expected costs on the go.")
            }.padding(.horizontal, 32)
            Spacer()
            Button {
                currentStep = 1
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
    
    private var locationView: some View {
        VStack {
            Spacer()
            Image(systemName: "location.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(.blue, Color.blue.opacity(0.2))
                .shadow(color: .blue.opacity(0.3), radius: 15, x: 0, y: 8)
                .padding(.bottom, 24)
            Text("Location Services")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.bottom, 48)
            VStack(alignment: .leading, spacing: 32) {
                FeatureRow(icon: "mappin.and.ellipse", color: .blue, title: "Nearby Stations", description: "Find nearby gas and service centers to easily log fill-ups and maintenance.")
                FeatureRow(icon: "clock.arrow.circlepath", color: .orange, title: "Locate Previous Data", description: "Automatically remember and auto-fill previous locations when logging.")
                FeatureRow(icon: "map.fill", color: .green, title: "Trip Tracking", description: "Effortlessly track your starting and ending coordinates for road trips.")
            }.padding(.horizontal, 32)
            Spacer()
            Button {
                locationManager.requestLocation()
                hasSeenSplash = true
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 36)).foregroundColor(color).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline.weight(.bold)); Text(description).font(.subheadline).foregroundColor(.secondary) }
        }
    }
}

// MARK: - Root View
struct ContentView: View {
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
    @AppStorage("lastSelectedVehicleID") private var lastSelectedVehicleID: String = ""
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("hasSeenSplash") private var hasSeenSplash: Bool = false
    
    @State private var showingAddVehicle = false
    @StateObject private var quickActionManager = QuickActionManager.shared
    @State private var quickActionTarget: QuickActionManager.QuickAction?

    var unarchivedVehicles: [Vehicle] { vehicles.filter { !$0.isArchived } }
    var selectedVehicle: Vehicle? { unarchivedVehicles.first(where: { $0.id.uuidString == lastSelectedVehicleID }) ?? unarchivedVehicles.first }

    var body: some View {
        ZStack {
            if !hasSeenSplash {
                SplashScreenView(hasSeenSplash: $hasSeenSplash).transition(.move(edge: .bottom).combined(with: .opacity)).zIndex(2)
            } else {
                Group {
                    if unarchivedVehicles.isEmpty {
                        EmptyGarageView(showingAdd: $showingAddVehicle)
                    } else if let vehicle = selectedVehicle {
                        MainDashboardView(vehicle: vehicle, allVehicles: unarchivedVehicles, onSelectVehicle: { newID in lastSelectedVehicleID = newID.uuidString })
                    }
                }.transition(.opacity).zIndex(1)
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: hasSeenSplash)
        .fontDesign(.rounded)
        .onAppear { applyTheme(appTheme) }
        .onChange(of: appTheme) { _, newTheme in applyTheme(newTheme) }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() } }
        .sheet(item: $quickActionTarget) { target in
            if let vehicle = selectedVehicle {
                if target == .addFuel { NavigationStack { AddFillUpView(vehicle: vehicle) } }
                else if target == .addService { NavigationStack { AddServiceView(vehicle: vehicle) } }
            }
        }
        .onChange(of: quickActionManager.action) { _, action in
            guard let action = action else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if action == .addVehicle { showingAddVehicle = true }
                else if selectedVehicle != nil { quickActionTarget = action }
                else { showingAddVehicle = true }
                quickActionManager.action = nil
            }
        }
        .onOpenURL { url in
            guard url.scheme == "fuellog" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if url.host == "addFuel" { quickActionManager.action = .addFuel }
                else if url.host == "addService" { quickActionManager.action = .addService }
            }
        }
    }
    
    private func applyTheme(_ theme: AppTheme) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for window in windowScene.windows {
            switch theme {
            case .system: window.overrideUserInterfaceStyle = .unspecified
            case .light: window.overrideUserInterfaceStyle = .light
            case .dark: window.overrideUserInterfaceStyle = .dark
            }
        }
    }
}

// MARK: - Empty State
struct EmptyGarageView: View {
    @Binding var showingAdd: Bool
    @Environment(\.modelContext) private var modelContext
    @StateObject private var csvImporter = CSVImporter()
    
    @State private var showingImportSourcePicker = false
    @State private var showFileImporter = false
    @State private var pendingImportSource: ImportSource = .none
    @State private var selectedEncoding: ExportEncoding = .utf8
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "door.garage.open")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .foregroundStyle(Color.accentColor)
                        .padding(24)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        
                    Text("Empty Garage").font(.title2.weight(.heavy))
                    Text("Add a vehicle to start logging your journey,\nor import your existing data.").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.offset(y: -40)
                
                VStack(spacing: 16) {
                    Spacer()
                    Button { showingAdd = true } label: {
                        Text("Add Vehicle").font(.headline.weight(.bold)).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.accentColor).clipShape(Capsule())
                    }
                    Button { showingImportSourcePicker = true } label: {
                        Text("Import CSV").font(.headline.weight(.bold)).foregroundColor(.accentColor).padding().frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
                    }
                    .confirmationDialog("Select Source App", isPresented: $showingImportSourcePicker, titleVisibility: .visible) {
                        ForEach(ImportSource.allCases) { source in
                            Button(source.rawValue) { pendingImportSource = source; showFileImporter = true }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Select the app that generated your CSV.")
                    }
                }.padding(24)
            }
            .navigationTitle("Garage")
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText]) { result in
                if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                    if let data = try? String(contentsOf: url, encoding: selectedEncoding.stringEncoding) {
                        Task { await csvImporter.performImport(data: data, source: pendingImportSource, modelContext: modelContext) }
                    }
                    url.stopAccessingSecurityScopedResource()
                }
            }
            .overlay { if csvImporter.isImporting { ProgressOverlay(title: "Importing Data...", progress: csvImporter.importProgress) } }
        }
    }
}

// MARK: - Unified Timeline Models
enum VehicleEvent: Identifiable, Hashable, Equatable {
    case fillUp(FillUp), service(ServiceRecord)
    var id: UUID { switch self { case .fillUp(let f): return f.id; case .service(let s): return s.id } }
    static func == (lhs: VehicleEvent, rhs: VehicleEvent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    var date: Date { switch self { case .fillUp(let f): return f.date; case .service(let s): return s.date } }
    var odometer: Double? { switch self { case .fillUp(let f): return f.odometer; case .service(let s): return s.odometer } }
    var icon: String { switch self { case .fillUp: return "fuelpump.fill"; case .service(let s): return s.type.icon } }
    var color: Color { switch self { case .fillUp: return .blue; case .service(let s): return s.type.color } }
    var cost: Double { switch self { case .fillUp(let f): return f.totalCost; case .service(let s): return s.cost } }
    var vehicle: Vehicle? { switch self { case .fillUp(let f): return f.vehicle; case .service(let s): return s.vehicle } }
    var title: String {
        switch self {
        case .fillUp(let f): return f.location?.name.isEmpty == false ? f.location!.name : "Fuel Station"
        case .service(let s): return s.location?.name.isEmpty == false ? s.location!.name : "Service"
        }
    }
    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .fillUp(let f): return f.location?.latitude != 0 ? CLLocationCoordinate2D(latitude: f.location!.latitude, longitude: f.location!.longitude) : nil
        case .service(let s): return s.location?.latitude != 0 ? CLLocationCoordinate2D(latitude: s.location!.latitude, longitude: s.location!.longitude) : nil
        }
    }
}

// MARK: - Current Location Manager
class CurrentLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    var onLocationUpdate: ((CLLocation) -> Void)?
    
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest }
    func requestLocation() { manager.requestWhenInUseAuthorization(); manager.startUpdatingLocation() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        self.location = loc; self.onLocationUpdate?(loc); manager.stopUpdatingLocation()
    }
}

// MARK: - Main Dashboard
struct MainDashboardView: View {
    @Environment(\.colorScheme) var colorScheme
    let vehicle: Vehicle
    let allVehicles: [Vehicle]
    let onSelectVehicle: (UUID) -> Void
    
    @State private var showFullScreenMap = false
    @State private var useSatellite = false
    @State private var selectedEventID: UUID?
    @State private var mapEventToView: VehicleEvent?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var sheetDetent: PresentationDetent = .fraction(0.35)
    @State private var selectedLogTab: LogTabChoice = .fuel
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var isMapReady = false
    
    var timelineEvents: [VehicleEvent] {
        let fills = vehicle.fillUps.map(VehicleEvent.fillUp), svcs = vehicle.services.map(VehicleEvent.service)
        return (fills + svcs).sorted { $0.date > $1.date }
    }
    
    var displayedEvents: [VehicleEvent] {
        timelineEvents.filter { selectedLogTab == .fuel ? (String(describing: $0).contains("fillUp")) : (String(describing: $0).contains("service")) }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if isMapReady {
                FlightPathMap(events: displayedEvents, showLines: false, mapStyle: colorScheme == .dark ? .standard : (useSatellite ? .imagery : .standard), bottomPadding: 320, selectedItemID: $selectedEventID, position: $mapPosition)
                    .transition(.opacity)
                    .onChange(of: selectedEventID) { _, newID in
                        if let id = newID, let ev = displayedEvents.first(where: { $0.id == id }) { mapEventToView = ev; selectedEventID = nil }
                    }
                    .sheet(item: $mapEventToView) { ev in RecordReadOnlyDetailView(event: ev) }
            }
            
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if colorScheme != .dark {
                            Button { useSatellite.toggle() } label: { Image(systemName: useSatellite ? "map.fill" : "globe.americas.fill").font(.title3).foregroundColor(.primary).padding(12).background(.regularMaterial).clipShape(Circle()).shadow(radius: 2) }
                        }
                        Button {
                            if let loc = locationManager.location { withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else {
                                locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) }; locationManager.onLocationUpdate = nil }
                                locationManager.requestLocation()
                            }
                        } label: { Image(systemName: "location.fill").font(.title3).foregroundColor(.primary).padding(12).background(.regularMaterial).clipShape(Circle()).shadow(radius: 2) }
                    }.padding().opacity(isMapReady ? 1 : 0)
                }
                Spacer()
            }
            .fullScreenCover(isPresented: $showFullScreenMap) { NavigationStack { VehicleMapView(vehicle: vehicle, useSatellite: $useSatellite, selectedTab: selectedLogTab, initialSelection: nil) } }
        }
        .onAppear { locationManager.requestLocation(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation(.easeIn(duration: 0.3)) { isMapReady = true } } }
        .sheet(isPresented: .constant(true)) {
            DashboardSheetContent(vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, selectedLogTab: $selectedLogTab, sheetDetent: $sheetDetent)
                .presentationDetents([.fraction(0.35), .fraction(0.65), .large], selection: $sheetDetent)
                .presentationDragIndicator(.visible).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.65))).interactiveDismissDisabled()
                .presentationBackground(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
        }
        .onChange(of: sheetDetent) { _, newDetent in if newDetent != .fraction(0.35) { withAnimation(.easeInOut(duration: 0.8)) { mapPosition = .automatic } } }
    }
}

enum LogTabChoice: String, CaseIterable, Identifiable { case fuel = "Fuel Logs", service = "Service Logs"; var id: String { rawValue } }

// MARK: - Dashboard Bottom Sheet
struct DashboardSheetContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) var colorScheme
    let vehicle: Vehicle
    let allVehicles: [Vehicle]
    let events: [VehicleEvent]
    let onSelectVehicle: (UUID) -> Void
    @Binding var selectedLogTab: LogTabChoice
    @Binding var sheetDetent: PresentationDetent
    
    @State private var showingAddFillUp = false
    @State private var showingAddService = false
    @State private var showingTrips = false
    @State private var showingSettings = false
    @State private var showingArchivedVehicles = false
    @State private var showingAddVehicle = false
    @State private var showingDeleteConfirmation = false
    @State private var isDropdownOpen = false
    @State private var eventToEdit: VehicleEvent?
    @State private var vehicleToEdit: Vehicle?
    
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                VStack(spacing: 0) {
                    FlightyStatsGrid(vehicle: vehicle, selectedTab: selectedLogTab).padding(.horizontal, 24).padding(.bottom, 24)
                    quickActionButtons
                    if vehicle.isMaintenanceDue { MaintenanceAlertView().padding(.horizontal, 24).padding(.bottom, 16) }
                    
                    Picker("Log View", selection: $selectedLogTab) { ForEach(LogTabChoice.allCases) { tab in Text(tab.rawValue).tag(tab) } }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search logs...", text: $searchText)
                    }
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    
                    logViewArea
                }
            }
        }
        .overlay(alignment: .topLeading) { dropdownMenu }
        .sheet(isPresented: $showingAddFillUp) { NavigationStack { AddFillUpView(vehicle: vehicle) } }
        .sheet(isPresented: $showingAddService) { NavigationStack { AddServiceView(vehicle: vehicle) } }
        .sheet(item: $eventToEdit) { ev in NavigationStack { switch ev { case .fillUp(let f): AddFillUpView(vehicle: vehicle, editingFillUp: f); case .service(let s): AddServiceView(vehicle: vehicle, editingService: s) } } }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() } }
        .sheet(item: $vehicleToEdit) { v in NavigationStack { AddVehicleView(editingVehicle: v) } }
        .sheet(isPresented: $showingArchivedVehicles) { ArchivedVehiclesView() }
        .alert("Delete \(vehicle.name)?", isPresented: $showingDeleteConfirmation) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { modelContext.delete(vehicle); try? modelContext.save() } } message: { Text("This will permanently delete this vehicle and all logs.") }
        .fullScreenCover(isPresented: $showingTrips) { NavigationStack { TripsListView(vehicle: vehicle) } }
        .fullScreenCover(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
    }
    
    private var headerBar: some View {
        HStack(spacing: 16) {
            Button { if !isDropdownOpen && sheetDetent == .fraction(0.35) { sheetDetent = .fraction(0.65) }; withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isDropdownOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(vehicle.name).font(.title2.weight(.heavy)).foregroundColor(.primary).lineLimit(2)
                    Image(systemName: isDropdownOpen ? "chevron.up" : "chevron.down").font(.subheadline.weight(.bold)).foregroundColor(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                Button { showingAddVehicle = true } label: { Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundColor(.primary).frame(width: 44, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
                Button { showingTrips = true } label: { Image(systemName: "map.fill").font(.system(size: 20)).foregroundColor(.primary).frame(width: 44, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
                Button { showingSettings = true } label: { Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(.primary).frame(width: 44, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
            }
        }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
    }
    
    private var quickActionButtons: some View {
        HStack(spacing: 12) {
            Button { showingAddFillUp = true } label: { Label("Fuel", systemImage: "fuelpump.fill").font(.headline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.blue, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).foregroundColor(.white) }
            Button { showingAddService = true } label: { Label("Service", systemImage: "wrench.and.screwdriver.fill").font(.headline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 14).background(Color.orange, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).foregroundColor(.white) }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }
    
    private var filteredEvents: [VehicleEvent] {
        let isFuelTab = selectedLogTab == .fuel
        let baseEvents = events.filter { ev in
            isFuelTab ? (String(describing: ev).contains("fillUp")) : (String(describing: ev).contains("service"))
        }
        
        if searchText.isEmpty { return baseEvents }
        let lower = searchText.localizedLowercase
        return baseEvents.filter { ev in
            switch ev {
            case .fillUp(let f):
                return f.location?.name.localizedLowercase.contains(lower) == true || f.notes.localizedLowercase.contains(lower)
            case .service(let s):
                return s.location?.name.localizedLowercase.contains(lower) == true || s.notes.localizedLowercase.contains(lower) || s.type.rawValue.localizedLowercase.contains(lower)
            }
        }
    }
    
    @ViewBuilder
    private var logViewArea: some View {
        VStack(spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredEvents.isEmpty {
                    Text(searchText.isEmpty ? (selectedLogTab == .fuel ? "No fuel logs yet." : "No service logs yet.") : "No logs match your search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                } else {
                    ForEach(Array(filteredEvents.enumerated()), id: \.element.id) { index, event in
                        let prevOdo: Double? = selectedLogTab == .fuel ? filteredEvents[(index + 1)...].first(where: { $0.odometer != nil })?.odometer : nil
                        TimelineRow(event: event, isFirst: index == 0, isLast: index == filteredEvents.count - 1, previousOdometer: prevOdo, distanceUnit: vehicle.odometerUnit.rawValue.lowercased())
                            .contentShape(Rectangle())
                            .onTapGesture { eventToEdit = event }
                            .contextMenu { Button("Edit") { eventToEdit = event }; Button("Delete", role: .destructive) { deleteEvent(event) } }
                    }
                }
            }
        }.padding(.bottom, 100)
    }
    
    @ViewBuilder private var dropdownMenu: some View {
        if isDropdownOpen {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isDropdownOpen = false } }
                VStack(alignment: .leading, spacing: 14) {
                    if allVehicles.count > 4 {
                        ScrollView {
                            vehicleListItems
                        }.frame(maxHeight: 250).scrollIndicators(.hidden)
                    } else {
                        vehicleListItems
                    }
                    Divider()
                    Button { vehicleToEdit = vehicle; withAnimation { isDropdownOpen = false } } label: { HStack(spacing: 10) { Image(systemName: "checkmark").opacity(0); Text("Edit Vehicle...") }.foregroundColor(.primary) }
                    Button { vehicle.isArchived = true; try? modelContext.save(); withAnimation { isDropdownOpen = false }; if let newV = allVehicles.first(where: { $0.id != vehicle.id }) { onSelectVehicle(newV.id) } } label: { HStack(spacing: 10) { Image(systemName: "checkmark").opacity(0); Text("Archive Vehicle") }.foregroundColor(.primary) }
                    Divider()
                    Button { showingArchivedVehicles = true; withAnimation { isDropdownOpen = false } } label: { HStack(spacing: 10) { Image(systemName: "checkmark").opacity(0); Text("Archived Vehicles") }.foregroundColor(.primary) }
                    Divider()
                    Button { showingDeleteConfirmation = true; withAnimation { isDropdownOpen = false } } label: { HStack(spacing: 10) { Image(systemName: "checkmark").opacity(0); Text("Delete Vehicle") }.foregroundColor(.red) }
                }
                .font(.title2.weight(.heavy)).padding(.vertical, 16).padding(.trailing, 24).padding(.leading, 12).fixedSize(horizontal: true, vertical: false)
                .background(ZStack { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial); RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.4)) })
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(LinearGradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.3 : 0.8), Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15), radius: 20, x: 0, y: 10).padding(.top, 64).padding(.leading, 24).transition(.scale(scale: 0.95, anchor: .topLeading).combined(with: .opacity))
            }.zIndex(20)
        }
    }
    
    private var vehicleListItems: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(allVehicles) { v in
                Button { onSelectVehicle(v.id); withAnimation { isDropdownOpen = false } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").opacity(v.id == vehicle.id ? 1 : 0)
                        Text(v.name)
                    }.foregroundColor(.primary)
                }
            }
        }.padding(.vertical, 4)
    }
    
    private func deleteEvent(_ event: VehicleEvent) {
        switch event { case .fillUp(let f): modelContext.delete(f); case .service(let s): modelContext.delete(s) }
        try? modelContext.save()
    }
}

struct MaintenanceAlertView: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("MAINTENANCE DUE").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                Text("Time for an oil change & inspection.").font(.body).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding()
        .background(Color.red, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Archived Vehicles View
struct ArchivedVehiclesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]

    var body: some View {
        NavigationStack {
            List(vehicles.filter { $0.isArchived }) { vehicle in
                NavigationLink(destination: ArchivedVehicleDetailView(vehicle: vehicle)) { Text(vehicle.name).font(.headline) }
                .swipeActions(edge: .trailing) { Button("Unarchive") { vehicle.isArchived = false; try? modelContext.save() }.tint(.blue) }
            }
            .navigationTitle("Archived Vehicles").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .overlay { if vehicles.filter({ $0.isArchived }).isEmpty { ContentUnavailableView("No Archived Vehicles", systemImage: "archivebox") } }
        }
    }
}

struct ArchivedVehicleDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    @State private var eventToView: VehicleEvent?

    var timelineEvents: [VehicleEvent] { (vehicle.fillUps.map(VehicleEvent.fillUp) + vehicle.services.map(VehicleEvent.service)).sorted { $0.date > $1.date } }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if timelineEvents.isEmpty { ContentUnavailableView("No Logs", systemImage: "doc.text", description: Text("There are no fuel or service logs for this vehicle.")) } else {
                ScrollView { LazyVStack(spacing: 12) { ForEach(timelineEvents) { event in SelectedEventCard(event: event) { eventToView = event } } }.padding(.vertical) }
            }
        }
        .navigationTitle(vehicle.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Unarchive") { vehicle.isArchived = false; try? modelContext.save(); dismiss() } } }
        .sheet(item: $eventToView) { ev in RecordReadOnlyDetailView(event: ev) }
    }
}

// MARK: - Flight Path Map
struct FlightPathMap: View {
    let events: [VehicleEvent]
    let showLines: Bool
    let mapStyle: MapStyle
    let bottomPadding: CGFloat
    @Binding var selectedItemID: UUID?
    @Binding var position: MapCameraPosition
    
    var body: some View {
        Map(position: $position, selection: $selectedItemID) {
            if showLines { MapPolyline(coordinates: events.compactMap(\.coordinate)).stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)) }
            ForEach(events.filter { $0.coordinate != nil }.sorted { lhs, rhs in (lhs.icon == "fuelpump.fill") == (rhs.icon == "fuelpump.fill") ? lhs.date < rhs.date : rhs.icon == "fuelpump.fill" }) { event in
                Annotation(event.title, coordinate: event.coordinate!) {
                    Image(systemName: event.icon).font(.system(size: 14, weight: .bold)).foregroundColor(.white).frame(width: 32, height: 32).background(event.color, in: Circle()).overlay(Circle().stroke(Color.white, lineWidth: 2)).shadow(radius: 3, y: 2)
                }.tag(event.id)
            }
            if #available(iOS 17.0, *) { UserAnnotation() }
        }.mapStyle(mapStyle).safeAreaPadding(.bottom, bottomPadding).safeAreaPadding(.top, 80).safeAreaPadding(.horizontal, 40)
    }
}

// MARK: - Stats Grid
struct FlightyStatsGrid: View {
    let vehicle: Vehicle
    let selectedTab: LogTabChoice
    
    var body: some View {
        HStack(spacing: 12) {
            FlightyStatBox(value: vehicle.lastOdometer != nil ? "\(Int(vehicle.totalDistanceLogged).formatted())" : "--", unit: vehicle.odometerUnit.rawValue.lowercased(), alignment: selectedTab == .service ? .center : .leading)
            
            let isFuelStat = selectedTab != .service
            if isFuelStat { FlightyStatBox(value: vehicle.averageEfficiency != nil ? String(format: "%.1f", vehicle.averageEfficiency!) : "--", unit: vehicle.efficiencyUnit.rawValue, alignment: .center) }
            
            FlightyStatBox(value: (isFuelStat ? vehicle.totalFuelCost : vehicle.totalServiceCost) > 0 ? (isFuelStat ? vehicle.totalFuelCost : vehicle.totalServiceCost).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")) : "--", unit: "total \(isFuelStat ? "fuel" : "service") cost", alignment: selectedTab == .service ? .center : .trailing)
        }
    }
}

struct FlightyStatBox: View {
    let value: String
    let unit: String
    var alignment: HorizontalAlignment
    
    var body: some View {
        VStack(alignment: alignment, spacing: -2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.primary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            if !unit.isEmpty { Text(unit).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.5) }
        }.frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center)).padding(.vertical, 12)
    }
}

// MARK: - Timeline Row
struct TimelineRow: View {
    let event: VehicleEvent
    let isFirst: Bool
    let isLast: Bool
    let previousOdometer: Double?
    let distanceUnit: String
    
    var singleLineDetailText: String {
        var parts = [event.date.formatted(date: .abbreviated, time: .omitted)]
        if let odo = event.odometer {
            parts.append("\(Int(odo).formatted())")
            if case .fillUp = event, let prev = previousOdometer, odo > prev { parts.append("\(Int(odo - prev).formatted()) \(distanceUnit == "miles" ? "mile" : "km") trip") }
        }
        if case .service(let s) = event { parts.append(s.type.rawValue) }
        return parts.joined(separator: " • ")
    }
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Color(uiColor: .separator)).frame(width: 3)
                ZStack { Circle().fill(event.color).frame(width: 28, height: 28); Image(systemName: event.icon).font(.system(size: 14, weight: .bold)).foregroundColor(.white) }.padding(.vertical, 8)
                Rectangle().fill(isLast ? Color.clear : Color(uiColor: .separator)).frame(width: 3)
            }.frame(width: 44)
            
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text(event.title).font(.headline.weight(.bold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true); Text(singleLineDetailText).font(.body.weight(.medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Text(event.cost, format: .currency(code: "USD")).font(.title3.weight(.heavy)).foregroundStyle(.primary).monospacedDigit()
            }.padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous)).padding(.vertical, 6).padding(.trailing, 24)
        }
    }
}

// MARK: - Vehicle Map Full View
struct VehicleMapView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    let vehicle: Vehicle
    @Binding var useSatellite: Bool
    let selectedTab: LogTabChoice
    let initialSelection: VehicleEvent?
    
    @State private var position: MapCameraPosition
    @State private var selectedItemID: UUID?
    @State private var eventToView: VehicleEvent?
    
    init(vehicle: Vehicle, useSatellite: Binding<Bool>, selectedTab: LogTabChoice, initialSelection: VehicleEvent? = nil) {
        self.vehicle = vehicle
        self._useSatellite = useSatellite
        self.selectedTab = selectedTab
        self.initialSelection = initialSelection
        self._selectedItemID = State(initialValue: initialSelection?.id)
        self._position = State(initialValue: (initialSelection?.coordinate != nil) ? .region(MKCoordinateRegion(center: initialSelection!.coordinate!, latitudinalMeters: 1000, longitudinalMeters: 1000)) : .automatic)
    }
    
    var timelineEvents: [VehicleEvent] {
        (vehicle.fillUps.map(VehicleEvent.fillUp) + vehicle.services.map(VehicleEvent.service)).filter { ev in
            ev.coordinate != nil && (selectedTab == .fuel ? String(describing: ev).contains("fillUp") : String(describing: ev).contains("service"))
        }.sorted { $0.date < $1.date }
    }
    
    var body: some View {
        ZStack {
            FlightPathMap(events: timelineEvents, showLines: false, mapStyle: colorScheme == .dark ? .standard : (useSatellite ? .imagery : .standard), bottomPadding: 0, selectedItemID: $selectedItemID, position: $position)
                .onChange(of: selectedItemID) { _, newID in if let id = newID, let ev = timelineEvents.first(where: { $0.id == id }), let coord = ev.coordinate { withAnimation(.easeInOut(duration: 0.5)) { position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 250, longitudinalMeters: 250)) } } }
                .sheet(item: $eventToView) { ev in RecordReadOnlyDetailView(event: ev).onDisappear { selectedItemID = nil } }
            
            VStack {
                Spacer()
                if let id = selectedItemID, let event = timelineEvents.first(where: { $0.id == id }) {
                    SelectedEventCard(event: event) { eventToView = event }
                }
            }
        }
        .animation(.easeInOut, value: selectedItemID).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary).font(.title3) } }
            if colorScheme != .dark { ToolbarItem(placement: .topBarTrailing) { Button { useSatellite.toggle() } label: { Image(systemName: useSatellite ? "map.fill" : "globe.americas.fill").foregroundStyle(.primary) } } }
        }
    }
}

// MARK: - Trip Map View (Full Screen)
struct TripMapView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    let trip: Trip
    let events: [VehicleEvent]
    
    @State private var useSatellite = false
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedItemID: UUID?
    @State private var eventToView: VehicleEvent?
    
    var body: some View {
        ZStack {
            FlightPathMap(events: events, showLines: true, mapStyle: colorScheme == .dark ? .standard : (useSatellite ? .imagery : .standard), bottomPadding: 0, selectedItemID: $selectedItemID, position: $position)
                .onChange(of: selectedItemID) { _, newID in if let id = newID, let ev = events.first(where: { $0.id == id }), let coord = ev.coordinate { withAnimation(.easeInOut(duration: 0.5)) { position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 250, longitudinalMeters: 250)) } } }
                .sheet(item: $eventToView) { ev in RecordReadOnlyDetailView(event: ev).onDisappear { selectedItemID = nil } }
            
            VStack {
                Spacer()
                if let id = selectedItemID, let event = events.first(where: { $0.id == id }) {
                    SelectedEventCard(event: event) { eventToView = event }
                }
            }
        }
        .animation(.easeInOut, value: selectedItemID).navigationTitle(trip.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary).font(.title3) } }
            if colorScheme != .dark { ToolbarItem(placement: .topBarTrailing) { Button { useSatellite.toggle() } label: { Image(systemName: useSatellite ? "map.fill" : "globe.americas.fill").foregroundStyle(.primary) } } }
        }
    }
}

// MARK: - Record Detail View
struct RecordReadOnlyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let event: VehicleEvent
    var body: some View {
        NavigationStack {
            List {
                Section("Log Information") { LabeledContent("Location", value: event.title); LabeledContent("Date", value: event.date.formatted(date: .abbreviated, time: .shortened)); LabeledContent("Cost", value: event.cost.formatted(.currency(code: "USD"))); if let odo = event.odometer { LabeledContent("Odometer", value: "\(Int(odo).formatted())") } }
                switch event {
                case .fillUp(let f):
                    Section("Fuel Details") { LabeledContent("Volume", value: "\(f.volume) \(f.unit.rawValue)"); LabeledContent("Price per Unit", value: f.pricePerUnit.formatted(.currency(code: "USD"))); if f.isFullTank { LabeledContent("Fill Type", value: "Full Tank") } }
                    if !f.notes.isEmpty { Section("Notes") { Text(f.notes).font(.body) } }
                case .service(let s):
                    Section("Service Details") { LabeledContent("Type", value: s.type.rawValue) }
                    if !s.notes.isEmpty { Section("Notes") { Text(s.notes).font(.body) } }
                }
            }
            .navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(.headline) } }
        }
    }
}

// MARK: - Trips View
struct TripsListView: View {
    let vehicle: Vehicle
    @Query(sort: \Trip.startDate, order: .reverse) private var allTrips: [Trip]
    @Query private var categories: [TripCategory]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAdd = false
    @State private var tripToEdit: Trip?
    
    var trips: [Trip] { allTrips.filter { $0.vehicle?.id == vehicle.id } }
    
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            List {
                Section { NavigationLink(destination: TripCostCalculatorView()) { HStack { Image(systemName: "dollarsign.arrow.circlepath").font(.title3.weight(.bold)).foregroundStyle(Color.accentColor); Text("Trip Cost Calculator").font(.headline.weight(.bold)) }.padding(.vertical, 4) }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground)) }
                Section("Trip Log") {
                    ForEach(trips) { trip in
                        NavigationLink(destination: TripDetailView(trip: trip)) { TripRow(trip: trip) }
                        .swipeActions(edge: .leading) { Button { tripToEdit = trip } label: { Label("Edit", systemImage: "pencil") } }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    }.onDelete { offsets in for i in offsets { modelContext.delete(trips[i]) }; try? modelContext.save() }
                }
            }
            .overlay(Group { if trips.isEmpty { VStack { Spacer(); ContentUnavailableView("No Trips", systemImage: "map", description: Text("Tap + to log your first trip for \(vehicle.name).")); Spacer() }.offset(y: 40) } })
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Trips")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary).font(.title3) } }; ToolbarItem(placement: .topBarTrailing) { Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title2) } } }
        .sheet(isPresented: $showingAdd) { NavigationStack { AddTripView(defaultVehicle: vehicle) } }
        .sheet(item: $tripToEdit) { t in NavigationStack { AddTripView(editingTrip: t) } }
        .onAppear { if categories.isEmpty { ["Business", "Personal", "Vacation"].forEach { modelContext.insert(TripCategory(name: $0)) }; try? modelContext.save() } }
    }
}

struct TripRow: View {
    let trip: Trip
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(trip.name).font(.headline.weight(.bold)); Spacer(); if let v = trip.vehicle { Text(v.name).font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.blue.opacity(0.2), in: Capsule()) }; if let cat = trip.category { Text(cat.name).font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.secondary.opacity(0.2), in: Capsule()) } }
            HStack { Image(systemName: "clock"); if trip.startDate == .distantPast { Text("All Time") } else { Text(trip.startDate, style: .date); Text("-"); if trip.endDate == .distantFuture { Text("Present") } else { Text(trip.endDate, style: .date) } } }.font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if let dist = trip.distance, dist > 0 { HStack { Image(systemName: "point.topleft.down.curvedto.point.bottomright.up"); Text("\(Int(dist).formatted()) distance").monospacedDigit() }.font(.caption.weight(.heavy)) }
        }.padding(.vertical, 4)
    }
}

struct TripDetailView: View {
    let trip: Trip
    @Query private var allFillUps: [FillUp]
    @Query private var allServices: [ServiceRecord]
    
    @State private var showingEdit = false
    @State private var selectedEventID: UUID?
    @State private var eventToEdit: VehicleEvent?
    @State private var mapEventToView: VehicleEvent?
    @State private var showFullScreenMap = false
    
    var relevantEvents: [VehicleEvent] {
        let f = allFillUps.filter { fill in if let tv = trip.vehicle, fill.vehicle?.id != tv.id { return false }; guard fill.date >= trip.startDate && fill.date <= trip.endDate else { return false }; if let tStart = trip.startOdometer, let tEnd = trip.endOdometer, let fOdo = fill.odometer { return fOdo >= tStart && fOdo <= tEnd }; return true }.map { VehicleEvent.fillUp($0) }
        let s = allServices.filter { service in if let tv = trip.vehicle, service.vehicle?.id != tv.id { return false }; guard service.date >= trip.startDate && service.date <= trip.endDate else { return false }; if let tStart = trip.startOdometer, let tEnd = trip.endOdometer { return service.odometer >= tStart && service.odometer <= tEnd }; return true }.map { VehicleEvent.service($0) }
        return (f + s).sorted { $0.date > $1.date }
    }
    var totalTripCost: Double { relevantEvents.map(\.cost).reduce(0, +) }
    var vehicleDistanceUnit: String { if let tv = trip.vehicle { return tv.odometerUnit.rawValue.lowercased() }; return allFillUps.first?.vehicle?.odometerUnit.rawValue.lowercased() ?? "distance" }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                .sheet(isPresented: $showingEdit) { NavigationStack { AddTripView(editingTrip: trip) } }
                .sheet(item: $eventToEdit) { ev in NavigationStack { switch ev { case .fillUp(let f): if let v = f.vehicle { AddFillUpView(vehicle: v, editingFillUp: f) }; case .service(let s): if let v = s.vehicle { AddServiceView(vehicle: v, editingService: s) } } } }
                .sheet(item: $mapEventToView) { ev in RecordReadOnlyDetailView(event: ev).onDisappear { selectedEventID = nil } }
                .fullScreenCover(isPresented: $showFullScreenMap) { NavigationStack { TripMapView(trip: trip, events: relevantEvents) } }
            
            ScrollView {
                VStack(spacing: 0) {
                    if !relevantEvents.filter({ $0.coordinate != nil }).isEmpty {
                        ZStack(alignment: .topTrailing) {
                            FlightPathMap(events: relevantEvents, showLines: true, mapStyle: .standard, bottomPadding: 0, selectedItemID: $selectedEventID, position: .constant(.automatic))
                                .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous)).padding(.horizontal, 8).padding(.top, 8)
                                .onChange(of: selectedEventID) { _, newID in if let id = newID, let ev = relevantEvents.first(where: { $0.id == id }) { mapEventToView = ev; selectedEventID = nil } }
                            Button { showFullScreenMap = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.subheadline.weight(.bold)).foregroundColor(.primary).padding(10).background(.regularMaterial).clipShape(Circle()).shadow(radius: 2) }.padding(16)
                        }.padding(.horizontal, 8).padding(.top, 8)
                    }
                    HStack(spacing: 12) {
                        let code = Locale.current.currency?.identifier ?? "USD"
                        FlightyStatBox(value: totalTripCost.formatted(.currency(code: code)), unit: "total \(code) cost", alignment: .center)
                        FlightyStatBox(value: trip.distance != nil ? "\(Int(trip.distance!).formatted())" : "--", unit: vehicleDistanceUnit, alignment: .center)
                    }.padding()
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TRIP LOGS").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
                        if relevantEvents.isEmpty { Text("No logs found for this trip.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 16) } else {
                            ForEach(Array(relevantEvents.enumerated()), id: \.element.id) { index, event in
                                TimelineRow(event: event, isFirst: index == 0, isLast: index == relevantEvents.count - 1, previousOdometer: relevantEvents[(index + 1)...].first(where: { $0.odometer != nil })?.odometer, distanceUnit: vehicleDistanceUnit)
                                .contentShape(Rectangle()).onTapGesture { eventToEdit = event }
                            }
                        }
                    }
                }
            }
        }.navigationTitle(trip.name).toolbar { Button("Edit") { showingEdit = true } }
    }
}

// MARK: - App Forms
struct AddVehicleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var editingVehicle: Vehicle?
    
    @State private var name: String = ""
    @State private var make: String = ""
    @State private var model: String = ""
    @State private var yearStr: String = ""
    @State private var odometerUnit: OdometerUnit = .miles
    @State private var fuelUnit: FuelUnit = .gallons
    @State private var efficiencyUnit: EfficiencyUnit = .mpgUS
    @State private var maintenanceIntervalStr: String = "5000"

    var body: some View {
        Form {
            Section("Basic Information") {
                FormTextField(title: "Name", placeholder: "e.g., My Daily", text: $name)
                FormTextField(title: "Make", placeholder: "e.g., Honda", text: $make)
                FormTextField(title: "Model", placeholder: "e.g., Civic", text: $model)
                FormTextField(title: "Year", placeholder: "e.g., 2018", text: $yearStr, keyboardType: .numberPad)
            }
            Section("Settings & Units") {
                Picker("Distance", selection: $odometerUnit) { ForEach(OdometerUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                Picker("Fuel", selection: $fuelUnit) { ForEach(FuelUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                Picker("Efficiency", selection: $efficiencyUnit) { ForEach(EfficiencyUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                FormTextField(title: "Maintenance Interval", placeholder: "e.g., 5000", text: $maintenanceIntervalStr, keyboardType: .numberPad)
            }
        }
        .navigationTitle(editingVehicle == nil ? "Add Vehicle" : "Edit Vehicle").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { saveVehicle() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        .onAppear {
            if let v = editingVehicle {
                name = v.name; make = v.make; model = v.model;
                if let y = v.year { yearStr = "\(y)" };
                odometerUnit = v.odometerUnit; fuelUnit = v.fuelUnit; efficiencyUnit = v.efficiencyUnit; maintenanceIntervalStr = "\(Int(v.maintenanceInterval))"
            }
        }
    }
    
    private func saveVehicle() {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.isEmpty else { return }
        if let v = editingVehicle {
            v.name = finalName; v.make = make; v.model = model; v.year = Int(yearStr); v.odometerUnit = odometerUnit; v.fuelUnit = fuelUnit; v.efficiencyUnit = efficiencyUnit; v.maintenanceInterval = Double(maintenanceIntervalStr) ?? 5000.0
        } else {
            let newVehicle = Vehicle(name: finalName, make: make, model: model, year: Int(yearStr), odometerUnit: odometerUnit, fuelUnit: fuelUnit, efficiencyUnit: efficiencyUnit)
            newVehicle.maintenanceInterval = Double(maintenanceIntervalStr) ?? 5000.0
            modelContext.insert(newVehicle); modelContext.insert(Trip(name: "Since Day One - \(newVehicle.name)", startDate: .distantPast, endDate: .distantFuture, vehicle: newVehicle))
        }
        try? modelContext.save(); dismiss()
    }
}

struct AddFillUpView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var previousLocations: [GasLocation]
    
    let vehicle: Vehicle
    var editingFillUp: FillUp?
    
    @State private var date: Date = .now
    @State private var locationName: String = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var showingMapPicker = false
    
    @State private var odometerStr: String = ""
    @State private var volumeStr: String = ""
    @State private var pricePerUnitStr: String = ""
    @State private var isFullTank: Bool = true
    @State private var notes: String = ""

    var locationMatches: [String] {
        guard !locationName.isEmpty else { return [] }
        let lower = locationName.localizedLowercase
        let matches = previousLocations.filter { $0.name.localizedLowercase.contains(lower) && $0.name.localizedLowercase != lower }
        return Array(Set(matches.map { $0.name })).sorted()
    }

    var body: some View {
        Form {
            Section("Fuel Log Details") {
                DatePicker("Date", selection: $date)
                LocationField(title: "Location", placeholder: "e.g., Costco", text: $locationName) { showingMapPicker = true }
                
                if !locationMatches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(locationMatches, id: \.self) { matchName in
                                Button(action: {
                                    locationName = matchName
                                    if let loc = previousLocations.first(where: { $0.name == matchName }) {
                                        latitude = loc.latitude
                                        longitude = loc.longitude
                                    }
                                }) {
                                    Text(matchName)
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
                FormTextField(title: "Volume (\(vehicle.fuelUnit.rawValue))", placeholder: "0.0", text: $volumeStr, keyboardType: .decimalPad)
                FormTextField(title: "Price / \(vehicle.fuelUnit.rawValue)", placeholder: "0.00", text: $pricePerUnitStr, keyboardType: .decimalPad)
                Toggle("Full Tank", isOn: $isFullTank)
            }
            Section("Notes") { TextEditor(text: $notes).frame(minHeight: 80) }
        }
        .navigationTitle(editingFillUp == nil ? "Log Fuel" : "Edit Fuel Log").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { saveFillUp() }.disabled(volumeStr.isEmpty || pricePerUnitStr.isEmpty) } }
        .sheet(isPresented: $showingMapPicker) { NavigationStack { LocationPickerView(latitude: $latitude, longitude: $longitude, locationName: $locationName) } }
        .onAppear { if let f = editingFillUp { date = f.date; locationName = f.location?.name ?? ""; latitude = f.location?.latitude ?? 0; longitude = f.location?.longitude ?? 0; if let o = f.odometer { odometerStr = "\(o)" }; volumeStr = "\(f.volume)"; pricePerUnitStr = "\(f.pricePerUnit)"; isFullTank = f.isFullTank; notes = f.notes } else if let lastOdo = vehicle.lastOdometer { odometerStr = "\(lastOdo)" } }
    }
    
    private func saveFillUp() {
        let vol = Double(volumeStr.replacingOccurrences(of: ",", with: ".")) ?? 0, ppu = Double(pricePerUnitStr.replacingOccurrences(of: ",", with: ".")) ?? 0, odo = Double(odometerStr.replacingOccurrences(of: ",", with: ".")), finalLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = editingFillUp {
            f.date = date; f.odometer = odo; f.volume = vol; f.pricePerUnit = ppu; f.isFullTank = isFullTank; f.notes = notes
            if let existingLoc = f.location { existingLoc.name = finalLocationName; existingLoc.latitude = latitude; existingLoc.longitude = longitude } else if !finalLocationName.isEmpty || latitude != 0 { let newLoc = GasLocation(name: finalLocationName, latitude: latitude, longitude: longitude); modelContext.insert(newLoc); f.location = newLoc }
        } else {
            var newLoc: GasLocation? = nil
            if !finalLocationName.isEmpty || latitude != 0 { let loc = GasLocation(name: finalLocationName, latitude: latitude, longitude: longitude); modelContext.insert(loc); newLoc = loc }
            modelContext.insert(FillUp(date: date, odometer: odo, volume: vol, pricePerUnit: ppu, isFullTank: isFullTank, notes: notes, unit: vehicle.fuelUnit, vehicle: vehicle, location: newLoc))
        }
        try? modelContext.save(); dismiss()
    }
}

struct AddServiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var previousLocations: [GasLocation]
    
    let vehicle: Vehicle
    var editingService: ServiceRecord?
    
    @State private var date: Date = .now
    @State private var locationName: String = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var showingMapPicker = false
    
    @State private var odometerStr: String = ""
    @State private var type: ServiceType = .general
    @State private var costStr: String = ""
    @State private var notes: String = ""

    var locationMatches: [String] {
        guard !locationName.isEmpty else { return [] }
        let lower = locationName.localizedLowercase
        let matches = previousLocations.filter { $0.name.localizedLowercase.contains(lower) && $0.name.localizedLowercase != lower }
        return Array(Set(matches.map { $0.name })).sorted()
    }

    var body: some View {
        Form {
            Section("Service Details") {
                DatePicker("Date", selection: $date)
                LocationField(title: "Location", placeholder: "e.g., Jiffy Lube", text: $locationName) { showingMapPicker = true }
                
                if !locationMatches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(locationMatches, id: \.self) { matchName in
                                Button(action: {
                                    locationName = matchName
                                    if let loc = previousLocations.first(where: { $0.name == matchName }) {
                                        latitude = loc.latitude
                                        longitude = loc.longitude
                                    }
                                }) {
                                    Text(matchName)
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
        .onAppear { if let s = editingService { date = s.date; locationName = s.location?.name ?? ""; latitude = s.location?.latitude ?? 0; longitude = s.location?.longitude ?? 0; odometerStr = "\(s.odometer)"; type = s.type; costStr = "\(s.cost)"; notes = s.notes } else if let lastOdo = vehicle.lastOdometer { odometerStr = "\(lastOdo)" } }
    }
    
    private func saveService() {
        let odo = Double(odometerStr.replacingOccurrences(of: ",", with: ".")) ?? 0, cost = Double(costStr.replacingOccurrences(of: ",", with: ".")) ?? 0, finalLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = editingService {
            s.date = date; s.odometer = odo; s.type = type; s.cost = cost; s.notes = notes
            if let existingLoc = s.location { existingLoc.name = finalLocationName; existingLoc.latitude = latitude; existingLoc.longitude = longitude } else if !finalLocationName.isEmpty || latitude != 0 { let newLoc = GasLocation(name: finalLocationName, latitude: latitude, longitude: longitude); modelContext.insert(newLoc); s.location = newLoc }
        } else {
            var newLoc: GasLocation? = nil
            if !finalLocationName.isEmpty || latitude != 0 { let loc = GasLocation(name: finalLocationName, latitude: latitude, longitude: longitude); modelContext.insert(loc); newLoc = loc }
            modelContext.insert(ServiceRecord(date: date, odometer: odo, type: type, cost: cost, notes: notes, vehicle: vehicle, location: newLoc))
        }
        try? modelContext.save(); dismiss()
    }
}

struct AddTripView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var defaultVehicle: Vehicle?, editingTrip: Trip?
    @Query(sort: \Vehicle.name) private var allVehicles: [Vehicle]
    @Query private var categories: [TripCategory]
    
    @State private var name: String = ""
    @State private var startDate: Date = .now
    @State private var endDate: Date = .now
    @State private var startOdoStr: String = ""
    @State private var endOdoStr: String = ""
    @State private var selectedVehicle: Vehicle?
    @State private var selectedCategory: TripCategory?

    var body: some View {
        Form {
            Section("Trip Identity") {
                FormTextField(title: "Trip Name", placeholder: "e.g., Roadtrip", text: $name)
                Picker("Vehicle", selection: $selectedVehicle) { Text("Select a Vehicle").tag(Vehicle?.none); ForEach(allVehicles) { v in Text(v.name).tag(v as Vehicle?) } }
                Picker("Category", selection: $selectedCategory) { Text("None").tag(TripCategory?.none); ForEach(categories) { c in Text(c.name).tag(c as TripCategory?) } }
            }
            Section("Date & Time") { DatePicker("Start Date", selection: $startDate); DatePicker("End Date", selection: $endDate) }
            Section("Distance Tracking (Optional)") {
                FormTextField(title: "Start Odometer", placeholder: "0.0", text: $startOdoStr, keyboardType: .decimalPad)
                FormTextField(title: "End Odometer", placeholder: "0.0", text: $endOdoStr, keyboardType: .decimalPad)
            }
        }
        .navigationTitle(editingTrip == nil ? "Log Trip" : "Edit Trip").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { saveTrip() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        .onAppear { if let t = editingTrip { name = t.name; startDate = t.startDate; endDate = t.endDate; if let so = t.startOdometer { startOdoStr = "\(so)" }; if let eo = t.endOdometer { endOdoStr = "\(eo)" }; selectedVehicle = t.vehicle; selectedCategory = t.category } else { selectedVehicle = defaultVehicle ?? allVehicles.first } }
    }
    
    private func saveTrip() {
        let startOdo = Double(startOdoStr.replacingOccurrences(of: ",", with: ".")), endOdo = Double(endOdoStr.replacingOccurrences(of: ",", with: "."))
        if let t = editingTrip { t.name = name; t.startDate = startDate; t.endDate = endDate; t.startOdometer = startOdo; t.endOdometer = endOdo; t.vehicle = selectedVehicle; t.category = selectedCategory } else {
            modelContext.insert(Trip(name: name, startDate: startDate, endDate: endDate, startOdometer: startOdo, endOdometer: endOdo, category: selectedCategory, vehicle: selectedVehicle))
        }
        try? modelContext.save(); dismiss()
    }
}

struct TripCostCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var distanceStr = ""
    @State private var efficiencyStr = ""
    @State private var priceStr = ""
    
    var estimatedCost: Double {
        let dist = Double(distanceStr.replacingOccurrences(of: ",", with: ".")) ?? 0, eff = Double(efficiencyStr.replacingOccurrences(of: ",", with: ".")) ?? 0, price = Double(priceStr.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard eff > 0 else { return 0 }
        return (dist / eff) * price
    }
    
    var body: some View {
        Form {
            Section(header: Text("Trip Details")) {
                FormTextField(title: "Total Distance", placeholder: "Miles/Km", text: $distanceStr, keyboardType: .decimalPad)
                FormTextField(title: "Vehicle Efficiency", placeholder: "MPG/L/100km", text: $efficiencyStr, keyboardType: .decimalPad)
                FormTextField(title: "Fuel Price", placeholder: "Per Unit", text: $priceStr, keyboardType: .decimalPad)
            }
            Section(header: Text("Estimated Cost")) { Text(estimatedCost.formatted(.currency(code: "USD"))).font(.largeTitle.weight(.bold)).foregroundStyle(.blue).frame(maxWidth: .infinity, alignment: .center).padding() }
        }.navigationTitle("Cost Calculator").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
}

// MARK: - Location Picker View
struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var latitude: Double
    @Binding var longitude: Double
    @Binding var locationName: String
    
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedCoord: CLLocationCoordinate2D?
    
    @State private var searchQuery = ""
    @State private var searchResults: [MKMapItem] = []
    
    var body: some View {
        ZStack(alignment: .top) {
            MapReader { reader in
                Map(position: $position) {
                    if let selectedCoord { Annotation(locationName.isEmpty ? "Selected" : locationName, coordinate: selectedCoord) { Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red).background(Color.white, in: Circle()).shadow(radius: 3) } }
                    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) { UserAnnotation() }
                }
                .onTapGesture(coordinateSpace: .local) { tapPosition in
                    if let pinLocation = reader.convert(tapPosition, from: .local) {
                        selectedCoord = pinLocation; latitude = pinLocation.latitude; longitude = pinLocation.longitude
                        Task {
                            let geocoder = CLGeocoder()
                            let location = CLLocation(latitude: pinLocation.latitude, longitude: pinLocation.longitude)
                            if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                                locationName = placemark.name ?? placemark.thoroughfare ?? locationName
                            }
                        }
                    }
                }
            }
            
            // Search Bar & Results
            VStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search nearby...", text: $searchQuery)
                        .onSubmit { performSearch() }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchResults.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                
                if !searchResults.isEmpty {
                    List(searchResults, id: \.self) { item in
                        Button {
                            selectSearchResult(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Unknown").font(.headline).foregroundColor(.primary)
                                Text(item.placemark.title ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .listRowBackground(Color(uiColor: .systemBackground).opacity(0.9))
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 250)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .shadow(radius: 5)
                }
            }
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        if let loc = locationManager.location { withAnimation(.easeInOut) { position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else { locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut) { position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } }; locationManager.requestLocation() }
                    } label: { Image(systemName: "location.fill").font(.title3).padding().background(.regularMaterial).clipShape(Circle()).shadow(radius: 4) }.padding()
                }
            }
            
            VStack { Spacer(); Text("Tap anywhere to manually drop a pin").font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).padding(.bottom, 24) }
        }
        .navigationTitle("Select Location").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            if latitude != 0 && longitude != 0 {
                let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                selectedCoord = coord
                position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000))
            } else if !locationName.isEmpty {
                searchQuery = locationName
                locationManager.onLocationUpdate = { loc in
                    if selectedCoord == nil {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = locationName
                        request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
                        MKLocalSearch(request: request).start { response, _ in
                            if let first = response?.mapItems.first {
                                selectSearchResult(first)
                            }
                        }
                    }
                }
                locationManager.requestLocation()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if selectedCoord == nil {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = locationName
                        MKLocalSearch(request: request).start { response, _ in
                            if let first = response?.mapItems.first {
                                selectSearchResult(first)
                            }
                        }
                    }
                }
            } else {
                locationManager.onLocationUpdate = { loc in
                    if latitude == 0 && longitude == 0 {
                        position = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000))
                    }
                }
                locationManager.requestLocation()
            }
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchQuery
        if let loc = locationManager.location {
            request.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        }
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            guard let response = response else { return }
            searchResults = response.mapItems
        }
    }
    
    private func selectSearchResult(_ item: MKMapItem) {
        searchQuery = ""
        searchResults.removeAll()
        
        let coord = item.placemark.coordinate
        selectedCoord = coord
        latitude = coord.latitude
        longitude = coord.longitude
        locationName = item.name ?? item.placemark.title ?? item.placemark.name ?? ""
        
        withAnimation {
            position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500))
        }
    }
}

// MARK: - Settings View & CSV Export
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("lastSelectedVehicleID") private var lastSelectedVehicleID: String = ""
    @Query private var vehicles: [Vehicle]
    
    @State private var selectedEncoding: ExportEncoding = .utf8
    @State private var showFileExporter = false
    @State private var showFileImporter = false
    @State private var showingImportSourcePicker = false
    @State private var showingExportVehiclePicker = false
    @State private var showingPurgeConfirmation = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importProgress: Double = 0.0
    @State private var exportProgress: Double = 0.0
    @State private var pendingImportSource: ImportSource = .none
    @State private var csvDocument: CSVDocument?
    @State private var exportFilename = "VehicleData"
    
    var body: some View {
        Form {
            Section("Appearance") { Picker("Theme", selection: $appTheme) { ForEach(AppTheme.allCases) { theme in Text(theme.rawValue).tag(theme) } } }
            Section(header: Text("Sync & Backup")) {
                HStack { Image(systemName: "icloud.fill").foregroundStyle(.blue).font(.title2); VStack(alignment: .leading) { Text("iCloud Sync is Active").font(.headline); Text("Your logs are securely and automatically synced across your Apple devices in the background.").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 4)
            }
            
            Section("Manual Backup (Drive / Dropbox)") {
                Text("Tap Export to manually save a copy of your data to Google Drive, Dropbox, or local storage using the iOS Files app.").font(.caption).foregroundStyle(.secondary)
                Picker("CSV Text Encoding", selection: $selectedEncoding) { ForEach(ExportEncoding.allCases) { enc in Text(enc.rawValue).tag(enc) } }
                
                Button { showingExportVehiclePicker = true } label: { Label("Export Vehicle Data (CSV)", systemImage: "square.and.arrow.up") }
                .confirmationDialog("Select Vehicle to Export", isPresented: $showingExportVehiclePicker, titleVisibility: .visible) {
                    Button("All Vehicles") { Task { await generateCSV(for: nil) } }
                    ForEach(vehicles) { vehicle in Button("\(vehicle.name)\(vehicle.isArchived ? " (Archived)" : "")") { Task { await generateCSV(for: vehicle) } } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Choose which vehicle's logs to export, or export them all together.") }
                
                Button { showingImportSourcePicker = true } label: { Label("Import Vehicle Data (CSV)", systemImage: "square.and.arrow.down") }
                .confirmationDialog("Select Source App", isPresented: $showingImportSourcePicker, titleVisibility: .visible) {
                    ForEach(ImportSource.allCases) { source in Button(source.rawValue) { pendingImportSource = source; showFileImporter = true } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Select the app that generated your CSV so it can be formatted correctly.") }
            }
            
            Section(header: Text("Danger Zone")) {
                Button(role: .destructive) { showingPurgeConfirmation = true } label: { Label("Erase All App Data", systemImage: "trash.fill") }
                .alert("Erase All App Data?", isPresented: $showingPurgeConfirmation) { Button("Cancel", role: .cancel) {}; Button("Erase Everything", role: .destructive) { purgeAllData() } } message: { Text("This will permanently delete all vehicles, trips, categories, and logs. This action cannot be undone.") }
            }
            
            Section { NavigationLink(destination: AboutView()) { Text("About Fuel Log") } }
        }
        .navigationTitle("Settings").toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.primary).font(.title3) } } }
        .fileExporter(isPresented: $showFileExporter, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: exportFilename) { _ in }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.commaSeparatedText]) { result in
            if case .success(let url) = result, url.startAccessingSecurityScopedResource() {
                if let data = try? String(contentsOf: url, encoding: selectedEncoding.stringEncoding) {
                    isImporting = true
                    importProgress = 0.0
                    Task {
                        await performImport(data: data, source: pendingImportSource)
                        isImporting = false
                    }
                }
                url.stopAccessingSecurityScopedResource()
            }
        }
        .overlay {
            if isImporting { ProgressOverlay(title: "Importing Data...", progress: importProgress) }
            else if isExporting { ProgressOverlay(title: "Generating CSV...", progress: exportProgress) }
        }
    }
    
    private func purgeAllData() {
        do {
            try modelContext.delete(model: Vehicle.self)
            try modelContext.delete(model: Trip.self)
            try modelContext.delete(model: TripCategory.self)
            try modelContext.delete(model: GasLocation.self)
            try modelContext.save()
            lastSelectedVehicleID = ""
            dismiss()
        } catch { print("Failed to purge data: \(error)") }
    }
    
    @MainActor private func generateCSV(for targetVehicle: Vehicle?) async {
        isExporting = true; exportProgress = 0.0; exportFilename = targetVehicle != nil ? "\(targetVehicle!.name)_Logs" : "All_Vehicles_Logs"
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        var csvString = "Vehicle,Record Type,Date,Odometer,Cost,Details,Location,Notes\n"
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        let vehiclesToExport = targetVehicle == nil ? vehicles : [targetVehicle!]
        let totalEvents = vehiclesToExport.reduce(0) { $0 + $1.fillUps.count + $1.services.count }
        let totalDouble = Double(max(1, totalEvents)); var currentCount = 0.0
        
        for vehicle in vehiclesToExport {
            for f in vehicle.fillUps {
                csvString.append("\"\(vehicle.name)\",\"Fuel\",\"\(df.string(from: f.date))\",\"\(f.odometer != nil ? "\(f.odometer!)" : "")\",\"\(f.totalCost)\",\"\(f.volume) \(f.unit.rawValue)\",\"\(f.location?.name.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\",\"\(f.notes.replacingOccurrences(of: "\"", with: "\"\""))\"\n")
                currentCount += 1; if Int(currentCount) % 20 == 0 { exportProgress = currentCount / totalDouble; try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            for s in vehicle.services {
                csvString.append("\"\(vehicle.name)\",\"Service\",\"\(df.string(from: s.date))\",\"\(s.odometer)\",\"\(s.cost)\",\"\(s.type.rawValue)\",\"\(s.location?.name.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\",\"\(s.notes.replacingOccurrences(of: "\"", with: "\"\""))\"\n")
                currentCount += 1; if Int(currentCount) % 20 == 0 { exportProgress = currentCount / totalDouble; try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        exportProgress = 1.0; try? await Task.sleep(nanoseconds: 200_000_000)
        csvDocument = CSVDocument(text: csvString, encoding: selectedEncoding.stringEncoding); isExporting = false; showFileExporter = true
    }
    
    @MainActor private func performImport(data: String, source: ImportSource) async {
        let importer = CSVImporter()
        await importer.performImport(data: data, source: source, modelContext: modelContext)
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        List {
            VStack(spacing: 16) {
                AppLogoIcon()
                    .frame(width: 100, height: 100)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    .padding(.top, 24)
                
                Text("Fuel Log")
                    .font(.title2.weight(.bold))
                
                VStack(spacing: 6) {
                    Text("Jeremiah 29:11")
                        .foregroundStyle(.secondary)
                    
                    Text("Made in California, by a Ukrainian")
                        .foregroundStyle(.secondary)
                    
                    Text("No Subscription, Ever.")
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                    
                    Text("@Motosung, 2026")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 16)
            
            Section {
                Button(action: {
                    if let url = URL(string: "mailto:imotosung@icloud.com") {
                        openURL(url)
                    }
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Email Developer")
                            .foregroundStyle(.primary)
                    }
                }
                
                Button(action: { /* Rate action */ }) {
                    HStack(spacing: 16) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Rate and Review")
                            .foregroundStyle(.primary)
                    }
                }
                
                Button(action: {
                    if let url = URL(string: "https://buymecoffee.com/motosung") {
                        openURL(url)
                    }
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                            .frame(width: 24)
                        
                        Text("Support Developer")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .navigationTitle("About Fuel Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

