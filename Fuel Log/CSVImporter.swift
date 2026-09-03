import SwiftUI
import SwiftData
import Combine
import FuelLogShared

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
        case .fuelly:
            await importFuellyCSV(rows, modelContext: modelContext)
        case .fuelio:
            await importFuelioCSV(rows, modelContext: modelContext)
        case .mileIQ:
            await importMileIQCSV(rows, modelContext: modelContext)
        case .none:
            if rows.first?.first == "Vehicle" {
                await importNativeCSV(rows, modelContext: modelContext)
            } else if data.contains("ROAD TRIP CSV") || rows.first?.first?.contains("ROAD TRIP CSV") == true {
                await importRoadTripCSV(rows, modelContext: modelContext)
            } else {
                let header = (rows.first ?? []).map { $0.lowercased() }.joined(separator: " ")
                if header.contains("car_name") || header.contains("car name") || header.contains("fuelup_date") || header.contains("fuelup date") {
                    await importFuellyCSV(rows, modelContext: modelContext)
                } else if data.contains("## Vehicle") || data.contains("## Log") || header.contains("fuel_amount") || header.contains("price_per_liter") {
                    await importFuelioCSV(rows, modelContext: modelContext)
                } else if header.contains("start location") || header.contains("end location") || header.contains("classification") || header.contains("purpose") {
                    await importMileIQCSV(rows, modelContext: modelContext)
                } else {
                    await importNativeCSV(rows, modelContext: modelContext)
                }
            }
        }
        
        isImporting = false
    }
    
    private func parseFlexibleDate(_ dateStr: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-M-d H:mm:ss", "yyyy-M-d H:mm", "yyyy-M-d",
            "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "MM/dd/yyyy h:mm a", "MM/dd/yyyy", "M/d/yyyy H:mm", "M/d/yyyy h:mm a", "M/d/yyyy",
            "MM/dd/yy HH:mm", "MM/dd/yy h:mm a", "M/d/yy H:mm", "M/d/yy h:mm a", "MM/dd/yy", "M/d/yy",
            "yyyy/MM/dd", "yyyy/M/d",
            "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "dd.MM.yy HH:mm", "dd.MM.yy", "d.M.yyyy HH:mm", "d.M.yyyy"
        ]
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
            
            let date = dateFormatter.date(from: dateStr) ?? parseFlexibleDate(dateStr) ?? Date()
            let odo = Double(odoStr)
            let cost = Double(costStr) ?? 0
            let loc = locStr.isEmpty ? nil : GasLocation(name: locStr, latitude: 0, longitude: 0)
            
            if recordType == "Fuel" {
                let components = detailsStr.components(separatedBy: " ")
                let vol = components.first.flatMap { Double($0) } ?? 0
                let unit = FuelUnit(rawValue: components.dropFirst().joined(separator: " ")) ?? .gallons
                let pricePerUnit = vol > 0 ? (cost / vol) : 0
                // Fuel Grade is an optional trailing column added later.
                let grade = row.count > 8 ? FuelGrade(rawValue: row[8]) : nil

                if !(vehicle.fillUps ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(FillUp(date: date, odometer: odo, volume: vol, pricePerUnit: pricePerUnit, isFullTank: true, notes: notesStr, unit: unit, grade: grade, vehicle: vehicle, location: loc))
                }
            } else if recordType == "Service" {
                let type = ServiceType(rawValue: detailsStr) ?? .general
                if !(vehicle.services ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.type == type }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(ServiceRecord(date: date, odometer: odo ?? 0, type: type, cost: cost, notes: notesStr, vehicle: vehicle, location: loc))
                }
            }
        }
        try? modelContext.save()
    }
    
    private func field(_ row: [String], _ index: Int?) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index]
    }

    private func columnIndex(in header: [String], matching needles: [String]) -> Int? {
        header.firstIndex { col in
            let lower = col.lowercased()
            return needles.contains { lower.contains($0) }
        }
    }

    private func importFuellyCSV(_ rows: [[String]], modelContext: ModelContext) async {
        guard rows.count > 1 else { return }
        let header = rows[0].map { $0.lowercased() }
        guard let vehicleCol = columnIndex(in: header, matching: ["car_name", "car name", "vehicle name"]),
              let dateCol = columnIndex(in: header, matching: ["fuelup_date", "fuelup date", "fuelup"]) else { return }
        let odoCol = columnIndex(in: header, matching: ["odometer", "odo"])
        let volCol = columnIndex(in: header, matching: ["litre", "gallon"])
        let priceCol = columnIndex(in: header, matching: ["price"])
        let notesCol = columnIndex(in: header, matching: ["notes", "note", "tags"])
        let partialCol = columnIndex(in: header, matching: ["partial"])
        let latCol = columnIndex(in: header, matching: ["latitude"])
        let lonCol = columnIndex(in: header, matching: ["longitude", "long"])
        let brandCol = columnIndex(in: header, matching: ["brand", "station", "fueling station"])
        let unit: FuelUnit = header.contains(where: { $0.contains("gallon") }) ? .gallons : .liters

        let existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        var vehiclesByName = Dictionary(uniqueKeysWithValues: existingVehicles.map { ($0.name, $0) })
        let total = Double(max(1, rows.count - 1))

        for (index, row) in rows.dropFirst().enumerated() {
            if index % 20 == 0 { importProgress = Double(index) / total; try? await Task.sleep(nanoseconds: 10_000_000) }
            let name = field(row, vehicleCol).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let date = parseFlexibleDate(field(row, dateCol)) else { continue }

            let vehicle: Vehicle
            if let existing = vehiclesByName[name] {
                vehicle = existing
            } else {
                vehicle = Vehicle(name: name)
                modelContext.insert(vehicle)
                vehiclesByName[name] = vehicle
                modelContext.insert(Trip(name: "Since Day One - \(name)", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
            }

            let vol = Double(field(row, volCol).replacingOccurrences(of: ",", with: "")) ?? 0
            guard vol > 0 else { continue }
            let price = Double(field(row, priceCol).replacingOccurrences(of: ",", with: "")) ?? 0
            let odo = Double(field(row, odoCol).replacingOccurrences(of: ",", with: ""))
            let partial = field(row, partialCol).lowercased()
            let isFull = !(["1", "yes", "true"].contains(partial))
            let notes = field(row, notesCol)
            let brandName = field(row, brandCol).trimmingCharacters(in: .whitespacesAndNewlines)
            var loc: GasLocation? = nil
            if !brandName.isEmpty {
                let newLoc = GasLocation(name: brandName, latitude: Double(field(row, latCol)) ?? 0, longitude: Double(field(row, lonCol)) ?? 0)
                modelContext.insert(newLoc)
                loc = newLoc
            }

            if !(vehicle.fillUps ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                modelContext.insert(FillUp(date: date, odometer: odo, volume: vol, pricePerUnit: price, isFullTank: isFull, notes: notes, unit: unit, vehicle: vehicle, location: loc))
            }
        }
        try? modelContext.save()
    }

    private func importFuelioCSV(_ rows: [[String]], modelContext: ModelContext) async {
        let marker = { (row: [String]) -> String in (row.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if rows.contains(where: { marker($0).hasPrefix("##") }) {
            await importFuelioSectionedCSV(rows, modelContext: modelContext)
        } else {
            await importFuelioFlatCSV(rows, modelContext: modelContext)
        }
    }

    private func importFuelioSectionedCSV(_ rows: [[String]], modelContext: ModelContext) async {
        var vehicleName = "Imported Vehicle"
        var odometerUnit: OdometerUnit = .miles
        var fuelUnit: FuelUnit = .gallons
        var logHeader: [String] = []
        var logRows: [[String]] = []

        var i = 0
        while i < rows.count {
            let first = (rows[i].first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if first.hasPrefix("##") {
                let section = first
                i += 1
                var sectionRows: [[String]] = []
                while i < rows.count {
                    let row = rows[i]
                    let rowFirst = (row.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if rowFirst.hasPrefix("##") { break }
                    if !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { sectionRows.append(row) }
                    i += 1
                }
                if section.contains("Vehicle"), let headerRow = sectionRows.first, let dataRow = sectionRows.dropFirst().first(where: { !($0.first ?? "").isEmpty }) {
                    if let name = dataRow.first, !name.isEmpty { vehicleName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if let idx = headerRow.firstIndex(where: { $0.lowercased().contains("fuelunit") }), dataRow.indices.contains(idx) {
                        let fu = dataRow[idx].lowercased()
                        fuelUnit = (fu == "l" || fu.contains("liter") || fu.contains("litre")) ? .liters : .gallons
                    }
                    if let idx = headerRow.firstIndex(where: { $0.lowercased().contains("distunit") }), dataRow.indices.contains(idx) {
                        let du = dataRow[idx].lowercased()
                        odometerUnit = du.contains("km") ? .kilometers : .miles
                    }
                } else if section.contains("Log"), let headerRow = sectionRows.first {
                    logHeader = headerRow.map { $0.lowercased() }
                    logRows = Array(sectionRows.dropFirst())
                }
            } else {
                i += 1
            }
        }
        guard !logHeader.isEmpty else { return }

        let dateCol = columnIndex(in: logHeader, matching: ["data", "date"])
        let odoCol = columnIndex(in: logHeader, matching: ["odo"])
        let volCol = columnIndex(in: logHeader, matching: ["fuel"])
        let fullCol = columnIndex(in: logHeader, matching: ["full"])
        let priceCol = columnIndex(in: logHeader, matching: ["price"])
        let latCol = columnIndex(in: logHeader, matching: ["lat"])
        let lonCol = columnIndex(in: logHeader, matching: ["long"])
        let cityCol = columnIndex(in: logHeader, matching: ["city", "station"])
        let notesCol = columnIndex(in: logHeader, matching: ["note"])
        guard let dateCol, let volCol else { return }

        let existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        let vehicle: Vehicle
        if let existing = existingVehicles.first(where: { $0.name == vehicleName }) {
            vehicle = existing
        } else {
            vehicle = Vehicle(name: vehicleName)
            vehicle.odometerUnit = odometerUnit
            vehicle.fuelUnit = fuelUnit
            modelContext.insert(vehicle)
            modelContext.insert(Trip(name: "Since Day One - \(vehicleName)", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
        }

        let total = Double(max(1, logRows.count))
        for (index, row) in logRows.enumerated() {
            if index % 20 == 0 { importProgress = Double(index) / total; try? await Task.sleep(nanoseconds: 10_000_000) }
            guard let date = parseFlexibleDate(field(row, dateCol)) else { continue }
            let vol = Double(field(row, volCol)) ?? 0
            guard vol > 0 else { continue }
            let price = Double(field(row, priceCol)) ?? 0
            let pricePerUnit = price > vol ? price / vol : price
            let fullValue = field(row, fullCol).lowercased()
            let isFull = !(["0", "no", "false", "n", "partial"].contains(fullValue))
            let cityName = field(row, cityCol).trimmingCharacters(in: .whitespacesAndNewlines)
            var loc: GasLocation? = nil
            if !cityName.isEmpty {
                let newLoc = GasLocation(name: cityName, latitude: Double(field(row, latCol)) ?? 0, longitude: Double(field(row, lonCol)) ?? 0)
                modelContext.insert(newLoc)
                loc = newLoc
            }
            let notes = field(row, notesCol)
            if !(vehicle.fillUps ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                modelContext.insert(FillUp(date: date, odometer: Double(field(row, odoCol)), volume: vol, pricePerUnit: pricePerUnit, isFullTank: isFull, notes: notes, unit: fuelUnit, vehicle: vehicle, location: loc))
            }
        }
        try? modelContext.save()
    }

    private func importFuelioFlatCSV(_ rows: [[String]], modelContext: ModelContext) async {
        guard rows.count > 1 else { return }
        let header = rows[0].map { $0.lowercased() }
        let dateCol = columnIndex(in: header, matching: ["date"])
        let odoCol = columnIndex(in: header, matching: ["odometer", "odo"])
        let volCol = columnIndex(in: header, matching: ["fuel_amount", "fuel", "litre", "gallon"])
        let totalPriceCol = columnIndex(in: header, matching: ["total_price", "total price", "total cost", "cost", "total"])
        let ppuCol = columnIndex(in: header, matching: ["price_per_liter", "price per liter", "price_per_litre", "price"])
        let stationCol = columnIndex(in: header, matching: ["station", "city"])
        let notesCol = columnIndex(in: header, matching: ["note"])
        guard let dateCol, let volCol else { return }
        let fuelUnit: FuelUnit = header.contains(where: { $0.contains("liter") || $0.contains("litre") }) ? .liters : .gallons

        let existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        let vehicle: Vehicle
        if let existing = existingVehicles.first {
            vehicle = existing
        } else {
            vehicle = Vehicle(name: "Imported Vehicle")
            vehicle.fuelUnit = fuelUnit
            modelContext.insert(vehicle)
            modelContext.insert(Trip(name: "Since Day One - Imported Vehicle", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
        }

        let total = Double(max(1, rows.count - 1))
        for (index, row) in rows.dropFirst().enumerated() {
            if index % 20 == 0 { importProgress = Double(index) / total; try? await Task.sleep(nanoseconds: 10_000_000) }
            guard let date = parseFlexibleDate(field(row, dateCol)) else { continue }
            let vol = Double(field(row, volCol)) ?? 0
            guard vol > 0 else { continue }
            let pricePerUnit: Double
            if let totalPriceCol, let totalPrice = Double(field(row, totalPriceCol)) {
                pricePerUnit = totalPrice / vol
            } else {
                pricePerUnit = Double(field(row, ppuCol)) ?? 0
            }
            let stationName = field(row, stationCol).trimmingCharacters(in: .whitespacesAndNewlines)
            var loc: GasLocation? = nil
            if !stationName.isEmpty {
                let newLoc = GasLocation(name: stationName, latitude: 0, longitude: 0)
                modelContext.insert(newLoc)
                loc = newLoc
            }
            let notes = field(row, notesCol)
            if !(vehicle.fillUps ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                modelContext.insert(FillUp(date: date, odometer: Double(field(row, odoCol)), volume: vol, pricePerUnit: pricePerUnit, isFullTank: true, notes: notes, unit: fuelUnit, vehicle: vehicle, location: loc))
            }
        }
        try? modelContext.save()
    }

    private func importMileIQCSV(_ rows: [[String]], modelContext: ModelContext) async {
        guard rows.count > 1 else { return }
        let header = rows[0].map { $0.lowercased() }
        guard let startDateCol = columnIndex(in: header, matching: ["start date", "date"]),
              let distCol = columnIndex(in: header, matching: ["distance", "miles", "mileage"]) else { return }
        let startTimeCol = columnIndex(in: header, matching: ["start time", "time"])
        let endTimeCol = columnIndex(in: header, matching: ["end time"])
        let startLocCol = columnIndex(in: header, matching: ["start location", "start loc", "location"])
        let endLocCol = columnIndex(in: header, matching: ["end location", "end loc"])
        let classCol = columnIndex(in: header, matching: ["classification", "class"])
        let purposeCol = columnIndex(in: header, matching: ["purpose", "category"])
        let noteCol = columnIndex(in: header, matching: ["note", "description"])

        let existingVehicles = (try? modelContext.fetch(FetchDescriptor<Vehicle>())) ?? []
        let vehicle: Vehicle
        if let existing = existingVehicles.first {
            vehicle = existing
        } else {
            vehicle = Vehicle(name: "Imported Vehicle")
            modelContext.insert(vehicle)
            modelContext.insert(Trip(name: "Since Day One - Imported Vehicle", startDate: .distantPast, endDate: .distantFuture, vehicle: vehicle))
        }

        let existingCategories = (try? modelContext.fetch(FetchDescriptor<TripCategory>())) ?? []
        var categoryMap = Dictionary(uniqueKeysWithValues: existingCategories.map { ($0.name, $0) })
        var allTrips = (try? modelContext.fetch(FetchDescriptor<Trip>())) ?? []

        let total = Double(max(1, rows.count - 1))
        for (index, row) in rows.dropFirst().enumerated() {
            if index % 20 == 0 { importProgress = Double(index) / total; try? await Task.sleep(nanoseconds: 10_000_000) }
            let dateStr = field(row, startDateCol)
            guard let startDate = parseFlexibleDate(dateStr) else { continue }

            var endDate = startDate
            let startTime = field(row, startTimeCol).trimmingCharacters(in: .whitespaces)
            let endTime = field(row, endTimeCol).trimmingCharacters(in: .whitespaces)
            if !startTime.isEmpty, let d = parseFlexibleDate("\(dateStr) \(startTime)") { endDate = d }
            if !endTime.isEmpty, let d = parseFlexibleDate("\(dateStr) \(endTime)") { endDate = d }

            let distance = Double(field(row, distCol)) ?? 0
            let purpose = field(row, purposeCol).trimmingCharacters(in: .whitespaces)
            let classification = field(row, classCol).trimmingCharacters(in: .whitespaces)
            let label = purpose.isEmpty ? (classification.isEmpty ? "MileIQ Drive" : classification) : purpose
            let startLoc = field(row, startLocCol).trimmingCharacters(in: .whitespaces)
            let endLoc = field(row, endLocCol).trimmingCharacters(in: .whitespaces)

            var notes = field(row, noteCol)
            if distance > 0 {
                let distanceText = String(format: "%.1f mi", distance)
                notes = notes.isEmpty ? distanceText : "\(notes)\nDistance: \(distanceText)"
            }
            if !startLoc.isEmpty || !endLoc.isEmpty {
                let route = "\(startLoc) to \(endLoc)"
                notes = notes.isEmpty ? route : "\(notes)\n\(route)"
            }

            let catName = purpose.isEmpty ? classification : purpose
            var category: TripCategory? = nil
            if !catName.isEmpty {
                if let existing = categoryMap[catName] { category = existing }
                else {
                    let newCat = TripCategory(name: catName)
                    modelContext.insert(newCat)
                    categoryMap[catName] = newCat
                    category = newCat
                }
            }

            if !allTrips.contains(where: { $0.name == label && abs($0.startDate.timeIntervalSince(startDate)) < 86400 }) {
                let trip = Trip(name: label, startDate: startDate, endDate: endDate, category: category, vehicle: vehicle)
                modelContext.insert(trip)
                allTrips.append(trip)
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
                guard !first.lowercased().hasPrefix("odometer") else { continue }
                let vol = Double(row[3]) ?? 0
                let date = parseFlexibleDate(row[2]) ?? Date()
                let locStr = row.count > 9 ? row[9] : ""
                let loc = locStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : GasLocation(name: locStr, latitude: Double(row.count > 10 ? row[10] : "") ?? 0, longitude: Double(row.count > 11 ? row[11] : "") ?? 0)
                
                if !(vehicle.fillUps ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.volume == vol }) {
                    if let loc { modelContext.insert(loc) }
                    modelContext.insert(FillUp(date: date, odometer: Double(row[0]), volume: vol, pricePerUnit: Double(row[5]) ?? 0, isFullTank: (row.count > 7 ? row[7] : "") != "1", notes: row.count > 8 ? row[8] : "", unit: vehicle.fuelUnit, vehicle: vehicle, location: loc))
                }
            } else if currentSection == "MAINT", row.count >= 6 {
                let cost = Double(row[3]) ?? 0
                let date = parseFlexibleDate(row[1]) ?? Date()
                let locStr = row[5]
                let loc = locStr.isEmpty ? nil : GasLocation(name: locStr, latitude: Double(row.count > 15 ? row[15] : "") ?? 0, longitude: Double(row.count > 16 ? row[16] : "") ?? 0)
                
                let lowerDesc = row[0].lowercased()
                let type: ServiceType
                if lowerDesc.contains("oil") {
                    type = .oilChange
                } else if lowerDesc.contains("tire") || lowerDesc.contains("rotation") {
                    type = .tires
                } else if lowerDesc.contains("brake") {
                    type = .brakes
                } else if lowerDesc.contains("battery") {
                    type = .battery
                } else {
                    type = .general
                }
                
                let finalNote = row[4].isEmpty ? row[0] : "\(row[0]) - \(row[4])"
                
                if !(vehicle.services ?? []).contains(where: { abs($0.date.timeIntervalSince(date)) < 60 && $0.type == type && $0.cost == cost }) {
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
