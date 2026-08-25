// xcode: set sdk=iOS

//
//  MonthlyReportView.swift
//  Fuel Log
//

import SwiftUI
import SwiftData
import Charts
import CoreLocation
import MapKit
import PhotosUI
import StoreKit
import UniformTypeIdentifiers
import Combine
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications
@preconcurrency import Vision
import VisionKit
import AppIntents
import LocalAuthentication
import FuelLogShared

// MARK: - Date Helper

extension Date {
    var monthIdentifier: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: self)
    }

    var monthTitle: String {
        formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - Monthly Report Model

struct MonthlyReport: Identifiable {
    let id = UUID()
    let date: Date

    var title: String { date.monthTitle }
}

// MARK: - Monthly Report View

struct MonthlyReportView: View {
    let month: Date
    var isModal: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FillUp.date) private var allFillUps: [FillUp]
    @Query(sort: \ServiceRecord.date) private var allServices: [ServiceRecord]

    private var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: month)?.start ?? month
    }

    private var startOfNextMonth: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: startOfMonth) ?? month
    }

    private var monthFillUps: [FillUp] {
        allFillUps.filter { $0.date >= startOfMonth && $0.date < startOfNextMonth }.sorted { $0.date < $1.date }
    }

    private var monthServices: [ServiceRecord] {
        allServices.filter { $0.date >= startOfMonth && $0.date < startOfNextMonth }.sorted { $0.date < $1.date }
    }

    private var milesDriven: Double? {
        let odos = monthFillUps.compactMap(\.odometer) + monthServices.compactMap(\.odometer)
        guard let minO = odos.min(), let maxO = odos.max(), maxO > minO else { return nil }
        return maxO - minO
    }

    private var totalFuelCost: Double { monthFillUps.map(\.totalCost).reduce(0, +) }
    private var totalVolume: Double { monthFillUps.map(\.volume).reduce(0, +) }
    private var serviceCost: Double { monthServices.map(\.cost).reduce(0, +) }

    private var avgPricePerUnit: Double? {
        totalVolume > 0 ? totalFuelCost / totalVolume : nil
    }

    private var currencyCode: String {
        monthFillUps.first?.vehicle?.currencyRaw
            ?? allFillUps.first?.vehicle?.currencyRaw
            ?? "USD"
    }

    private var fuelUnitName: String {
        monthFillUps.first?.unit.rawValue ?? "units"
    }

    private var distanceUnitName: String {
        (monthFillUps.first?.vehicle?.odometerUnit ?? .miles).rawValue.lowercased()
    }

    private var mapEvents: [VehicleEvent] {
        monthFillUps.filter { ($0.location?.latitude ?? 0) != 0 }.map(VehicleEvent.fillUp)
    }

    private var hasMap: Bool { !mapEvents.isEmpty }
    private var hasActivity: Bool { !monthFillUps.isEmpty || !monthServices.isEmpty }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Here's how \(month.monthTitle) went.")
                        .font(.title3.weight(.heavy))

                    if hasMap {
                        FlightPathMap(events: mapEvents, showLines: false, mapStyle: .standard, bottomPadding: 0, selectedItemID: .constant(nil), position: .constant(.automatic), reservesRoomForAnnotationLabels: true)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    }

                    HStack(spacing: 12) {
                        FlightyStatBox(value: milesDriven.map { "\(Int($0).formatted())" } ?? "-", unit: distanceUnitName, alignment: .leading)
                        FlightyStatBox(value: "\(monthFillUps.count)", unit: "fuel stops", alignment: .center)
                        FlightyStatBox(value: totalFuelCost > 0 ? totalFuelCost.formatted(.currency(code: currencyCode)) : "-", unit: "fuel cost", alignment: .trailing)
                    }

                    HStack(spacing: 12) {
                        FlightyStatBox(value: totalVolume > 0 ? String(format: "%.1f", totalVolume) : "-", unit: fuelUnitName, alignment: .leading)
                        FlightyStatBox(value: avgPricePerUnit.map { String(format: "%.2f", $0) } ?? "-", unit: "avg price", alignment: .center)
                        FlightyStatBox(value: serviceCost > 0 ? serviceCost.formatted(.currency(code: currencyCode)) : "-", unit: "service cost", alignment: .trailing)
                    }

                    if !monthFillUps.isEmpty {
                        Text("FUEL STOPS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(monthFillUps) { fillUp in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fillUp.location?.name.isEmpty == false ? fillUp.location!.name : "Fuel Station")
                                        .font(.headline.weight(.bold))
                                    Text([fillUp.date.formatted(date: .abbreviated, time: .omitted), fillUp.effectiveGradeName]
                                        .compactMap { $0 }
                                        .joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.1f %@", fillUp.volume, fillUp.unit.rawValue))
                                        .font(.subheadline.weight(.bold))
                                    Text(fillUp.totalCost.formatted(.currency(code: currencyCode)))
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(month.monthTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .overlay {
            if !hasActivity {
                ContentUnavailableView("No Activity", systemImage: "calendar.badge.exclamationmark", description: Text("No fuel or service logs for \(month.monthTitle)."))
            }
        }
    }
}

// MARK: - All Monthly Reports

struct MonthlyReportsView: View {
    @Query(sort: \FillUp.date, order: .reverse) private var allFillUps: [FillUp]
    @Query(sort: \ServiceRecord.date, order: .reverse) private var allServices: [ServiceRecord]

    private var monthsWithData: [MonthlyReport] {
        var seen = Set<String>()
        var months: [MonthlyReport] = []
        let calendar = Calendar.current
        let dates = allFillUps.map(\.date) + allServices.map(\.date)
        for date in dates.sorted(by: >) {
            let key = date.monthIdentifier
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if let start = calendar.dateInterval(of: .month, for: date)?.start {
                months.append(MonthlyReport(date: start))
            }
        }
        return months
    }

    var body: some View {
        Group {
            if monthsWithData.isEmpty {
                ContentUnavailableView("No Reports Yet", systemImage: "clock.arrow.circlepath", description: Text("Your monthly reports will appear here after you log fuel or services."))
            } else {
                List {
                    Section("Monthly Reports") {
                        ForEach(monthsWithData) { report in
                            NavigationLink(destination: MonthlyReportView(month: report.date)) {
                                Label(report.title, systemImage: "calendar")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Monthly Reports")
        .navigationBarTitleDisplayMode(.inline)
    }
}
