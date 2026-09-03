// xcode: set sdk=iOS

//
//  ArchivedVehiclesView.swift
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

    var timelineEvents: [VehicleEvent] { ((vehicle.fillUps ?? []).map(VehicleEvent.fillUp) + (vehicle.services ?? []).map(VehicleEvent.service)).sorted { $0.date > $1.date } }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if timelineEvents.isEmpty { ContentUnavailableView("No Logs", systemImage: "doc.text", description: Text("There are no logs for this vehicle.")) } else {
                ScrollView { LazyVStack(spacing: 12) { ForEach(timelineEvents) { event in SelectedEventCard(event: event) { eventToView = event } } }.padding(.vertical) }
            }
        }
        .navigationTitle(vehicle.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Unarchive") { vehicle.isArchived = false; try? modelContext.save(); dismiss() } } }
        .sheet(item: $eventToView) { ev in RecordReadOnlyDetailView(event: ev) }
    }
}


