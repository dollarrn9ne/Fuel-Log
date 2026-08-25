// xcode: set sdk=iOS

//
//  TripViews.swift
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
                Section {
                    NavigationLink(destination: TripCostCalculatorView(currency: vehicle.currencyRaw)) {
                        HStack {
                            Image(systemName: "dollarsign.arrow.circlepath")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text("Trip Cost Calculator")
                                .font(.headline.weight(.bold))
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    NavigationLink(destination: MonthlyReportsView()) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text("Monthly Reports")
                                .font(.headline.weight(.bold))
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                }
                Section("Trip Log") {
                    ForEach(trips) { trip in
                        NavigationLink(destination: TripDetailView(trip: trip)) { TripRow(trip: trip) }
                        .swipeActions(edge: .leading) { Button { tripToEdit = trip } label: { Label("Edit", systemImage: "pencil") } }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    }.onDelete { offsets in 
                        for i in offsets { 
                            let trip = trips[i]
                            trip.vehicle?.trips?.removeAll(where: { $0.id == trip.id })
                            modelContext.delete(trip)
                        }
                        try? modelContext.save() 
                    }
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

    /// Total fuel logged during the trip, used for the trip efficiency figure.
    var tripFuelVolume: Double {
        relevantEvents.reduce(0) { total, event in
            if case .fillUp(let fill) = event { return total + fill.volume }
            return total
        }
    }
    /// Trip efficiency (distance / fuel logged), in the vehicle's efficiency unit.
    var tripEfficiency: Double? {
        guard let v = trip.vehicle, let dist = trip.distance, dist > 0, tripFuelVolume > 0 else { return nil }
        return EfficiencyConverter.convert(distance: dist, odometerUnit: v.odometerUnit, volume: tripFuelVolume, fuelUnit: v.fuelUnit, to: v.efficiencyUnit)
    }
    var efficiencyUnitLabel: String { trip.vehicle?.efficiencyUnit.rawValue ?? "MPG (US)" }

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
                            FlightPathMap(events: relevantEvents, showLines: true, mapStyle: .standard, bottomPadding: 0, selectedItemID: $selectedEventID, position: .constant(.automatic), reservesRoomForAnnotationLabels: true)
                                .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous)).padding(.horizontal, 8).padding(.top, 8)
                                .onChange(of: selectedEventID) { _, newID in if let id = newID, let ev = relevantEvents.first(where: { $0.id == id }) { mapEventToView = ev; selectedEventID = nil } }
                            Button { showFullScreenMap = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.subheadline.weight(.bold)).foregroundColor(.primary).padding(10).background(.regularMaterial).clipShape(Circle()).shadow(radius: 2) }.padding(16)
                        }.padding(.horizontal, 8).padding(.top, 8)
                    }
                    HStack(spacing: 12) {
                        let code = trip.vehicle?.currencyRaw ?? "USD"
                        FlightyStatBox(value: totalTripCost.formatted(.currency(code: code)), unit: "total \(code) cost", alignment: .center)
                        FlightyStatBox(value: tripEfficiency.map { String(format: "%.1f", $0) } ?? "-", unit: efficiencyUnitLabel, alignment: .center)
                        FlightyStatBox(value: trip.distance != nil ? "\(Int(trip.distance!).formatted())" : "-", unit: vehicleDistanceUnit, alignment: .center)
                    }.padding()
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TRIP LOGS").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
                        if relevantEvents.isEmpty { Text("No logs found for this trip.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 16) } else {
                            ForEach(Array(relevantEvents.enumerated()), id: \.element.id) { index, event in
                                TimelineRow(event: event, isFirst: index == 0, isLast: index == relevantEvents.count - 1, previousOdometer: relevantEvents[(index + 1)...].first(where: { $0.odometer != nil })?.odometer, distanceUnit: vehicleDistanceUnit, useGlassBackground: false)
                                .contentShape(Rectangle()).onTapGesture { eventToEdit = event }
                            }
                        }
                    }
                }
            }
        }.navigationTitle(trip.name).toolbar { Button("Edit") { showingEdit = true } }
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
        .onAppear { if let t = editingTrip { name = t.name; startDate = t.startDate; endDate = t.endDate; if let so = t.startOdometer { startOdoStr = so.odometerString }; if let eo = t.endOdometer { endOdoStr = eo.odometerString }; selectedVehicle = t.vehicle; selectedCategory = t.category } else { selectedVehicle = defaultVehicle ?? allVehicles.first } }
    }
    
    private func saveTrip() {
        let startOdo = Double(startOdoStr.replacingOccurrences(of: ",", with: ".")), endOdo = Double(endOdoStr.replacingOccurrences(of: ",", with: "."))
        if let t = editingTrip { t.name = name; t.startDate = startDate; t.endDate = endDate; t.startOdometer = startOdo; t.endOdometer = endOdo; t.vehicle = selectedVehicle; t.category = selectedCategory } else {
            let newTrip = Trip(name: name, startDate: startDate, endDate: endDate, startOdometer: startOdo, endOdometer: endOdo, category: selectedCategory, vehicle: selectedVehicle)
            modelContext.insert(newTrip)
            if selectedVehicle?.trips == nil { selectedVehicle?.trips = [] }
            selectedVehicle?.trips?.append(newTrip)
        }
        
        // Force UI update
        if let v = selectedVehicle {
            let temp = v.fuelUnitRaw
            v.fuelUnitRaw = ""
            v.fuelUnitRaw = temp
        }
        
        try? modelContext.save(); dismiss()
    }
}

struct TripCostCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    let currency: String
    
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
            Section(header: Text("Estimated Cost")) { Text(estimatedCost.formatted(.currency(code: currency))).font(.largeTitle.weight(.bold)).foregroundStyle(.blue).frame(maxWidth: .infinity, alignment: .center).padding() }
        }.navigationTitle("Cost Calculator").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
}


