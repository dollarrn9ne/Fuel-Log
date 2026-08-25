// xcode: set sdk=iOS

//
//  VehicleTimeline.swift
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
                }.padding(24).centredContentColumn()
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
    var icon: String { 
        switch self { 
        case .fillUp(let f): return f.unit == .kwh ? "bolt.car.fill" : "fuelpump.fill"
        case .service(let s): return s.type.icon 
        } 
    }
    var color: Color { 
        switch self { 
        case .fillUp(let f):
            if f.unit == .kwh { return .red }
            return f.vehicle?.fuelType == .diesel ? .green : .blue
        case .service(let s): return s.type.color 
        } 
    }
    var cost: Double { switch self { case .fillUp(let f): return f.totalCost; case .service(let s): return s.cost } }
    var vehicle: Vehicle? { switch self { case .fillUp(let f): return f.vehicle; case .service(let s): return s.vehicle } }
    var title: String {
        switch self {
        case .fillUp(let f): return f.location?.name.isEmpty == false ? f.location!.name : "Fuel Station"
        case .service(let s): return s.location?.name.isEmpty == false ? s.location!.name : "Service"
        }
    }
    var receiptData: Data? {
        switch self {
        case .fillUp(let f): return f.receiptData
        case .service(let s): return s.receiptData
        }
    }
    var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .fillUp(let f): 
            if let loc = f.location, loc.latitude != 0 {
                return CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
            }
            return nil
        case .service(let s): 
            if let loc = s.location, loc.latitude != 0 {
                return CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
            }
            return nil
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


