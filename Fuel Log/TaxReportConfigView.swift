import SwiftUI
import UIKit
import UniformTypeIdentifiers
import FuelLogShared

enum TaxExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case pdf = "PDF"
    var id: String { rawValue }
}

struct ReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .pdf] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct TaxRecord {
    let date: Date
    let kind: String
    let category: String
    let description: String
    let startOdometer: String
    let endOdometer: String
    let distance: String
    let cost: Double
    let notes: String
    let vehicleName: String
}

struct TaxReportConfigView: View {
    @Environment(\.dismiss) private var dismiss
    var vehicles: [Vehicle]
    
    @State private var selectedVehicleID: UUID? = nil
    @State private var timeframe: TaxTimeframe = .year
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    
    @State private var exportFormat: TaxExportFormat = .csv
    
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var showFileExporter = false
    @State private var reportDocument: ReportDocument?
    @State private var reportContentType: UTType = .commaSeparatedText
    @State private var exportFilename = "TaxReport"
    
    @State private var showSuccessOverlay = false
    
    var availableYears: [Int] {
        var years = Set<Int>()
        let calendar = Calendar.current
        for v in vehicles {
            for f in v.fillUps ?? [] { years.insert(calendar.component(.year, from: f.date)) }
            for s in v.services ?? [] { years.insert(calendar.component(.year, from: s.date)) }
            for t in v.trips ?? [] { years.insert(calendar.component(.year, from: t.startDate)) }
        }
        let filtered = years.filter { $0 > 1900 }
        if filtered.isEmpty { return [Calendar.current.component(.year, from: Date())] }
        return Array(filtered).sorted(by: >)
    }
    
    var body: some View {
        Form {
            Section("Vehicle Selection") {
                Picker("Vehicle", selection: $selectedVehicleID) {
                    Text("All Vehicles").tag(nil as UUID?)
                    ForEach(vehicles) { v in
                        Text(v.name).tag(v.id as UUID?)
                    }
                }
            }
            
            Section("Timeframe") {
                Picker("Timeframe", selection: $timeframe) {
                    ForEach(TaxTimeframe.allCases) { tf in
                        Text(tf.rawValue).tag(tf)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
                
                if timeframe == .year || timeframe == .month {
                    Picker("Year", selection: $selectedYear) {
                        ForEach(availableYears, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                }
                
                if timeframe == .month {
                    Picker("Month", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { month in
                            Text(Calendar.current.monthSymbols[month - 1]).tag(month)
                        }
                    }
                }
                
                if timeframe == .custom {
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                }
            }
            
            Section("Export Format") {
                Picker("Format", selection: $exportFormat) {
                    ForEach(TaxExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Section {
                Button(action: { Task { await generateReport() } }) {
                    HStack {
                        Spacer()
                        if isExporting {
                            ProgressView().padding(.trailing, 8)
                            Text("Generating...")
                        } else {
                            Text("Generate Report")
                                .font(.headline.weight(.bold))
                        }
                        Spacer()
                    }
                }
                .disabled(isExporting)
            }
        }
        .navigationTitle("Tax Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .fileExporter(isPresented: $showFileExporter, document: reportDocument, contentType: reportContentType, defaultFilename: exportFilename) { result in
            if case .success = result {
                withAnimation { showSuccessOverlay = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showSuccessOverlay = false }
                    dismiss()
                }
            }
        }
        .onAppear {
            if let maxYear = availableYears.first {
                selectedYear = maxYear
            }
        }
        .overlay {
            if showSuccessOverlay {
                SuccessOverlay(title: "Saved Successfully!")
            }
        }
    }
    
    @MainActor private func generateReport() async {
        isExporting = true
        exportProgress = 0.0
        
        let vehicleName = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.name.replacingOccurrences(of: " ", with: "") ?? "Vehicle") : "AllVehicles"
        switch timeframe {
        case .allTime: exportFilename = "\(vehicleName)_TaxReport_AllTime"
        case .year: exportFilename = "\(vehicleName)_TaxReport_\(selectedYear)"
        case .month: exportFilename = "\(vehicleName)_TaxReport_\(selectedYear)_\(selectedMonth)"
        case .custom: exportFilename = "\(vehicleName)_TaxReport_Custom"
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        
        let calendar = Calendar.current
        var allRecords: [(date: Date, record: TaxRecord)] = []
        
        let targetVehicles = selectedVehicleID != nil ? vehicles.filter { $0.id == selectedVehicleID } : vehicles
        let currencyCode = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.currencyRaw ?? "USD") : "USD"
        let vehicleLabel = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.name ?? "Vehicle") : "All Vehicles"
        
        for vehicle in targetVehicles {
            let escapedVehicleName = vehicle.name.replacingOccurrences(of: "\"", with: "\"\"")
            
            for f in vehicle.fillUps ?? [] {
                guard shouldInclude(f.date, calendar: calendar) else { continue }
                let desc = f.location?.name ?? "Fuel Station"
                let odo = f.odometer?.odometerString ?? ""
                let record = TaxRecord(
                    date: f.date,
                    kind: "Expense",
                    category: "Fuel",
                    description: desc,
                    startOdometer: "",
                    endOdometer: odo,
                    distance: "",
                    cost: f.totalCost,
                    notes: f.notes,
                    vehicleName: escapedVehicleName
                )
                allRecords.append((f.date, record))
            }
            
            for s in vehicle.services ?? [] {
                guard shouldInclude(s.date, calendar: calendar) else { continue }
                let record = TaxRecord(
                    date: s.date,
                    kind: "Expense",
                    category: "Maintenance",
                    description: s.type.rawValue,
                    startOdometer: "",
                    endOdometer: s.odometer.odometerString,
                    distance: "",
                    cost: s.cost,
                    notes: s.notes,
                    vehicleName: escapedVehicleName
                )
                allRecords.append((s.date, record))
            }
            
            for t in vehicle.trips ?? [] {
                guard shouldInclude(t.startDate, calendar: calendar) else { continue }
                let startOdo = t.startOdometer?.odometerString ?? ""
                let endOdo = t.endOdometer?.odometerString ?? ""
                let dist = t.distance != nil ? "\(t.distance!)" : ""
                let record = TaxRecord(
                    date: t.startDate,
                    kind: "Trip",
                    category: t.category?.name ?? "Uncategorized",
                    description: t.name,
                    startOdometer: startOdo,
                    endOdometer: endOdo,
                    distance: dist,
                    cost: 0,
                    notes: t.name,
                    vehicleName: escapedVehicleName
                )
                allRecords.append((t.startDate, record))
            }
        }
        
        allRecords.sort { $0.date < $1.date }
        let records = allRecords.map { $0.record }
        
        exportProgress = 1.0
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        switch exportFormat {
        case .csv:
            reportContentType = .commaSeparatedText
            reportDocument = ReportDocument(data: Data(makeCSV(records: records, dateFormatter: df).utf8))
        case .pdf:
            reportContentType = .pdf
            let timeframeLabel = timeframeLabelText
            reportDocument = ReportDocument(data: makePDF(records: records, vehicleLabel: vehicleLabel, timeframeLabel: timeframeLabel, currencyCode: currencyCode))
        }
        
        isExporting = false
        showFileExporter = true
    }
    
    private var timeframeLabelText: String {
        switch timeframe {
        case .allTime: return "All Time"
        case .year: return String(selectedYear)
        case .month: return "\(Calendar.current.monthSymbols[selectedMonth - 1]) \(selectedYear)"
        case .custom: return "\(startDate.formatted(date: .abbreviated, time: .omitted)) - \(endDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }
    
    private func makeCSV(records: [TaxRecord], dateFormatter: DateFormatter) -> String {
        var csvString = "Date,Type,Vehicle,Category,Description,Start Odometer,End Odometer,Distance,Cost,Notes\n"
        for record in records {
            let dateStr = dateFormatter.string(from: record.date)
            let desc = record.description.replacingOccurrences(of: "\"", with: "\"\"")
            let notes = record.notes.replacingOccurrences(of: "\"", with: "\"\"")
            let cost = record.cost > 0 ? "\(record.cost)" : ""
            let row = "\"\(dateStr)\",\"\(record.kind)\",\"\(record.vehicleName)\",\"\(record.category)\",\"\(desc)\",\"\(record.startOdometer)\",\"\(record.endOdometer)\",\"\(record.distance)\",\"\(cost)\",\"\(notes)\"\n"
            csvString.append(row)
        }
        return csvString
    }
    
    private func makePDF(records: [TaxRecord], vehicleLabel: String, timeframeLabel: String, currencyCode: String) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        
        let costFormatter = NumberFormatter()
        costFormatter.numberStyle = .currency
        costFormatter.currencyCode = currencyCode
        costFormatter.maximumFractionDigits = 2
        
        let totalCost = records.reduce(0) { $0 + $1.cost }
        let totalDistance = records.compactMap { Double($0.distance) }.reduce(0, +)
        let distanceUnit = vehicles.first(where: { $0.id == selectedVehicleID })?.odometerUnit.rawValue ?? "mi"
        
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18)]
        let sectionAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9)]
        let cellAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        
        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 40
            
            ("Fuel Log Tax Report").draw(at: CGPoint(x: 40, y: y), withAttributes: titleAttrs)
            y += 26
            ("\(vehicleLabel) • \(timeframeLabel)").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 16
            ("Generated: \(df.string(from: Date()))").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 14
            ("Total Expenses: \(costFormatter.string(from: NSNumber(value: totalCost)) ?? "\(totalCost)")").draw(at: CGPoint(x: 40, y: y), withAttributes: sectionAttrs)
            y += 16
            ("Total Distance: \(Int(totalDistance)) \(distanceUnit) • \(records.count) records").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 28
            
            func drawRow(_ text: String, at x: CGFloat, width: CGFloat, align: NSTextAlignment, attrs: [NSAttributedString.Key: Any]) {
                let rect = CGRect(x: x, y: y, width: width, height: 14)
                (text as NSString).draw(in: rect, withAttributes: attrs)
            }
            
            // Header row
            drawRow("Date", at: 40, width: 75, align: .left, attrs: headerAttrs)
            drawRow("Type", at: 115, width: 55, align: .left, attrs: headerAttrs)
            drawRow("Category", at: 170, width: 60, align: .left, attrs: headerAttrs)
            drawRow("Description", at: 230, width: 150, align: .left, attrs: headerAttrs)
            drawRow("Odometer", at: 380, width: 62, align: .right, attrs: headerAttrs)
            drawRow("Cost", at: 442, width: 130, align: .right, attrs: headerAttrs)
            y += 16
            // Separator line
            context.cgContext.setStrokeColor(UIColor.systemGray4.cgColor)
            context.cgContext.setLineWidth(0.5)
            context.cgContext.move(to: CGPoint(x: 40, y: y - 3))
            context.cgContext.addLine(to: CGPoint(x: 572, y: y - 3))
            context.cgContext.strokePath()
            
            for record in records {
                if y > 750 {
                    context.beginPage()
                    y = 40
                }
                let truncatedDesc = record.description.count > 24 ? String(record.description.prefix(23)) + "…" : record.description
                let odoText = record.endOdometer.isEmpty ? record.startOdometer : record.endOdometer
                let costText = record.cost > 0 ? (costFormatter.string(from: NSNumber(value: record.cost)) ?? "\(record.cost)") : ""
                
                drawRow(df.string(from: record.date), at: 40, width: 75, align: .left, attrs: cellAttrs)
                drawRow(record.kind, at: 115, width: 55, align: .left, attrs: cellAttrs)
                drawRow(record.category, at: 170, width: 60, align: .left, attrs: cellAttrs)
                drawRow(truncatedDesc, at: 230, width: 150, align: .left, attrs: cellAttrs)
                drawRow(odoText, at: 380, width: 62, align: .right, attrs: cellAttrs)
                drawRow(costText, at: 442, width: 130, align: .right, attrs: cellAttrs)
                y += 14
            }
        }
    }
    
    private func shouldInclude(_ date: Date, calendar: Calendar) -> Bool {
        switch timeframe {
        case .allTime:
            return true
        case .year:
            return calendar.component(.year, from: date) == selectedYear
        case .month:
            return calendar.component(.year, from: date) == selectedYear && calendar.component(.month, from: date) == selectedMonth
        case .custom:
            let start = calendar.startOfDay(for: startDate)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
            return date >= start && date <= end
        }
    }
}
