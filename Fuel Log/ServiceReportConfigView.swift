import SwiftUI
import UIKit
import UniformTypeIdentifiers
import FuelLogShared

private struct ServiceReportRecord {
    let date: Date
    let type: String
    let odometer: String
    let cost: Double
    let location: String
    let notes: String
    let vehicleName: String
}

struct ServiceReportConfigView: View {
    @Environment(\.dismiss) private var dismiss
    var vehicles: [Vehicle]

    @State private var selectedVehicleID: UUID? = nil
    @State private var timeframe: TaxTimeframe = .allTime
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()

    @State private var exportFormat: TaxExportFormat = .csv

    @State private var isExporting = false
    @State private var showFileExporter = false
    @State private var reportDocument: ReportDocument?
    @State private var reportContentType: UTType = .commaSeparatedText
    @State private var exportFilename = "ServiceReport"

    @State private var showSuccessOverlay = false

    var availableYears: [Int] {
        var years = Set<Int>()
        let calendar = Calendar.current
        for v in vehicles {
            for s in v.services ?? [] { years.insert(calendar.component(.year, from: s.date)) }
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
        .navigationTitle("Service Report")
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

        let vehicleName = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.name.replacingOccurrences(of: " ", with: "") ?? "Vehicle") : "AllVehicles"
        switch timeframe {
        case .allTime: exportFilename = "\(vehicleName)_ServiceReport_AllTime"
        case .year: exportFilename = "\(vehicleName)_ServiceReport_\(selectedYear)"
        case .month: exportFilename = "\(vehicleName)_ServiceReport_\(selectedYear)_\(selectedMonth)"
        case .custom: exportFilename = "\(vehicleName)_ServiceReport_Custom"
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none

        let calendar = Calendar.current
        var allRecords: [(date: Date, record: ServiceReportRecord)] = []

        let targetVehicles = selectedVehicleID != nil ? vehicles.filter { $0.id == selectedVehicleID } : vehicles
        let currencyCode = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.currencyRaw ?? "USD") : "USD"
        let vehicleLabel = selectedVehicleID != nil ? (vehicles.first { $0.id == selectedVehicleID }?.name ?? "Vehicle") : "All Vehicles"

        for vehicle in targetVehicles {
            let escapedVehicleName = vehicle.name.replacingOccurrences(of: "\"", with: "\"\"")

            for s in vehicle.services ?? [] {
                guard shouldInclude(s.date, calendar: calendar) else { continue }
                let record = ServiceReportRecord(
                    date: s.date,
                    type: s.type.rawValue,
                    odometer: s.odometer.odometerString,
                    cost: s.cost,
                    location: s.location?.name ?? "",
                    notes: s.notes,
                    vehicleName: escapedVehicleName
                )
                allRecords.append((s.date, record))
            }
        }

        allRecords.sort { $0.date < $1.date }
        let records = allRecords.map { $0.record }

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

    private func makeCSV(records: [ServiceReportRecord], dateFormatter: DateFormatter) -> String {
        var csvString = "Date,Type,Vehicle,Location,Odometer,Cost,Notes\n"
        for record in records {
            let dateStr = dateFormatter.string(from: record.date)
            let type = record.type.replacingOccurrences(of: "\"", with: "\"\"")
            let location = record.location.replacingOccurrences(of: "\"", with: "\"\"")
            let notes = record.notes.replacingOccurrences(of: "\"", with: "\"\"")
            let cost = record.cost > 0 ? "\(record.cost)" : ""
            let row = "\"\(dateStr)\",\"\(type)\",\"\(record.vehicleName)\",\"\(location)\",\"\(record.odometer)\",\"\(cost)\",\"\(notes)\"\n"
            csvString.append(row)
        }
        return csvString
    }

    private func makePDF(records: [ServiceReportRecord], vehicleLabel: String, timeframeLabel: String, currencyCode: String) -> Data {
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

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18)]
        let sectionAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9)]
        let cellAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]

        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 40

            ("Fuel Log Service Report").draw(at: CGPoint(x: 40, y: y), withAttributes: titleAttrs)
            y += 26
            ("\(vehicleLabel) • \(timeframeLabel)").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 16
            ("Generated: \(df.string(from: Date()))").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 14
            ("Total Service Cost: \(costFormatter.string(from: NSNumber(value: totalCost)) ?? "\(totalCost)")").draw(at: CGPoint(x: 40, y: y), withAttributes: sectionAttrs)
            y += 16
            ("\(records.count) service records").draw(at: CGPoint(x: 40, y: y), withAttributes: bodyAttrs)
            y += 28

            func drawRow(_ text: String, at x: CGFloat, width: CGFloat, align: NSTextAlignment, attrs: [NSAttributedString.Key: Any]) {
                let rect = CGRect(x: x, y: y, width: width, height: 14)
                (text as NSString).draw(in: rect, withAttributes: attrs)
            }

            drawRow("Date", at: 40, width: 70, align: .left, attrs: headerAttrs)
            drawRow("Type", at: 110, width: 95, align: .left, attrs: headerAttrs)
            drawRow("Location", at: 205, width: 160, align: .left, attrs: headerAttrs)
            drawRow("Odometer", at: 365, width: 65, align: .right, attrs: headerAttrs)
            drawRow("Cost", at: 430, width: 142, align: .right, attrs: headerAttrs)
            y += 16
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
                let truncatedLocation = record.location.count > 22 ? String(record.location.prefix(21)) + "…" : record.location
                let costText = record.cost > 0 ? (costFormatter.string(from: NSNumber(value: record.cost)) ?? "\(record.cost)") : ""

                drawRow(df.string(from: record.date), at: 40, width: 70, align: .left, attrs: cellAttrs)
                drawRow(record.type, at: 110, width: 95, align: .left, attrs: cellAttrs)
                drawRow(truncatedLocation, at: 205, width: 160, align: .left, attrs: cellAttrs)
                drawRow(record.odometer, at: 365, width: 65, align: .right, attrs: cellAttrs)
                drawRow(costText, at: 430, width: 142, align: .right, attrs: cellAttrs)
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
