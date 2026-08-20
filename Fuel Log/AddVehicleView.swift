// xcode: set sdk=iOS

//
//  AddVehicleView.swift
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

// MARK: - App Forms

// MARK: - Location Suggestion
struct LocationSuggestion: Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
    let isNearby: Bool
}

@MainActor
struct AddVehicleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    var editingVehicle: Vehicle?
    
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var photoData: Data? = nil
    
    @State private var name: String = ""
    @State private var make: String = ""
    @State private var model: String = ""
    @State private var yearStr: String = ""
    @State private var fuelType: FuelType = .gas
    @State private var defaultGrade: FuelGrade? = .regular
    @State private var odometerUnit: OdometerUnit = .miles
    @State private var fuelUnit: FuelUnit = .gallons
    @State private var efficiencyUnit: EfficiencyUnit = .mpgUS
    @State private var currency: Currency = .usd
    @State private var tankCapacityStr: String = ""
    @State private var batteryCapacityStr: String = ""
    @State private var maintenanceIntervalStr: String = "5000"
    @State private var maintenanceIntervalMonthsStr: String = "6"

    var body: some View {
        Form {
            VStack {
                let currentPhotoData = photoData
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    if let photoData = currentPhotoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.rectangle.badge.plus")
                                .font(.title)
                            Text("Passport Photo")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundColor(.secondary)
                        .frame(width: 90, height: 120)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                            await MainActor.run { photoData = data }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 8)
            
            Section("Basic Information") {
                FormTextField(title: "Name", placeholder: "e.g., My Daily", text: $name)
                FormTextField(title: "Make", placeholder: "e.g., Honda", text: $make)
                FormTextField(title: "Model", placeholder: "e.g., Civic", text: $model)
                FormTextField(title: "Year", placeholder: "e.g., 2018", text: $yearStr, keyboardType: .numberPad)
                Picker("Fuel Type", selection: $fuelType) { ForEach(FuelType.allCases) { t in Text(t.rawValue).tag(t) } }
            }
            Section("Settings & Units") {
                Picker("Currency", selection: $currency) { ForEach(Currency.allCases) { c in Text(c.rawValue).tag(c) } }
                Picker("Distance", selection: $odometerUnit) { ForEach(OdometerUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                Picker("Fuel / Energy", selection: $fuelUnit) { ForEach(FuelUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                // Vehicles that always take the same fuel set it once here
                // instead of on every fill-up. Flex-fuel is excluded on purpose:
                // choosing per fill-up is the whole point for those.
                if fuelType == .gas || fuelType == .plugInHybrid {
                    Picker("Fuel Grade", selection: $defaultGrade) {
                        ForEach(fuelType.availableGrades) { grade in
                            Text(grade.rawValue).tag(grade as FuelGrade?)
                        }
                    }
                }
                FormTextField(title: "Capacity (\(fuelUnit.rawValue))", placeholder: "e.g., 14.5", text: $tankCapacityStr, keyboardType: .decimalPad)
                if fuelType == .plugInHybrid {
                    FormTextField(title: "Capacity (kWh)", placeholder: "e.g., 8.8", text: $batteryCapacityStr, keyboardType: .decimalPad)
                }
                Picker("Efficiency", selection: $efficiencyUnit) { ForEach(EfficiencyUnit.allCases) { u in Text(u.rawValue).tag(u) } }
                FormTextField(title: "Maintenance Interval", placeholder: "e.g., 5000", text: $maintenanceIntervalStr, keyboardType: .numberPad)
                FormTextField(title: "Maintenance Interval (months)", placeholder: "e.g., 6", text: $maintenanceIntervalMonthsStr, keyboardType: .numberPad)
            }
        }
        .navigationTitle(editingVehicle == nil ? "Add Vehicle" : "Edit Vehicle").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { saveVehicle() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        .onAppear {
            if let v = editingVehicle {
                name = v.name; make = v.make; model = v.model;
                if let y = v.year { yearStr = "\(y)" };
                fuelType = v.fuelType; odometerUnit = v.odometerUnit; fuelUnit = v.fuelUnit; efficiencyUnit = v.efficiencyUnit; currency = v.currency; maintenanceIntervalStr = "\(Int(v.maintenanceInterval))"; maintenanceIntervalMonthsStr = "\(Int(v.maintenanceIntervalMonths))"
                if let cap = v.tankCapacity { tankCapacityStr = "\(cap)" }
                if let cap = v.batteryCapacity { batteryCapacityStr = "\(cap)" }
                defaultGrade = v.defaultFuelGrade
                photoData = v.photoData
            }
        }
        .onChange(of: fuelType) { _, newType in
            if newType == .electric {
                fuelUnit = .kwh
                efficiencyUnit = odometerUnit == .miles ? .miPerKWh : .kmPerKWh
            } else if fuelUnit == .kwh {
                fuelUnit = .gallons
                efficiencyUnit = odometerUnit == .miles ? .mpgUS : .l100km
            }
            // Keep the grade valid for the newly chosen fuel type.
            if let grade = defaultGrade, !newType.availableGrades.contains(grade) {
                defaultGrade = newType.defaultGrade
            } else if defaultGrade == nil {
                defaultGrade = newType.defaultGrade
            }
        }
    }
    
    private func saveVehicle() {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.isEmpty else { return }
        let parsedCapacity = Double(tankCapacityStr.replacingOccurrences(of: ",", with: "."))
        let parsedBatteryCapacity = Double(batteryCapacityStr.replacingOccurrences(of: ",", with: "."))
        
        let targetVehicle: Vehicle
        
        if let v = editingVehicle {
            v.name = finalName; v.make = make; v.model = model; v.year = Int(yearStr); v.fuelType = fuelType; v.odometerUnit = odometerUnit; v.fuelUnit = fuelUnit; v.efficiencyUnit = efficiencyUnit; v.currency = currency; v.maintenanceInterval = Double(maintenanceIntervalStr) ?? 5000.0
            v.maintenanceIntervalMonths = Double(maintenanceIntervalMonthsStr) ?? 6.0
            v.tankCapacity = parsedCapacity
            v.batteryCapacity = parsedBatteryCapacity
            v.defaultFuelGrade = defaultGrade
            v.photoData = photoData
            targetVehicle = v
        } else {
            let newVehicle = Vehicle(name: finalName, make: make, model: model, year: Int(yearStr), fuelType: fuelType, odometerUnit: odometerUnit, fuelUnit: fuelUnit, efficiencyUnit: efficiencyUnit, currency: currency, tankCapacity: parsedCapacity, batteryCapacity: parsedBatteryCapacity)
            newVehicle.maintenanceInterval = Double(maintenanceIntervalStr) ?? 5000.0
            newVehicle.maintenanceIntervalMonths = Double(maintenanceIntervalMonthsStr) ?? 6.0
            newVehicle.defaultFuelGrade = defaultGrade
            newVehicle.photoData = photoData
            modelContext.insert(newVehicle); modelContext.insert(Trip(name: "Since Day One - \(newVehicle.name)", startDate: .distantPast, endDate: .distantFuture, vehicle: newVehicle))
            targetVehicle = newVehicle
        }
        
        try? modelContext.save()
        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: targetVehicle)
        }
        dismiss()
    }
}


