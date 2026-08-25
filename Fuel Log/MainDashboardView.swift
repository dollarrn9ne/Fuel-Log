// xcode: set sdk=iOS

//
//  MainDashboardView.swift
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

// MARK: - Main Dashboard
struct MainDashboardView: View {
    @Environment(\.colorScheme) var colorScheme
    let vehicle: Vehicle
    let allVehicles: [Vehicle]
    let onSelectVehicle: (UUID) -> Void
    let newReportMonth: Date?
    let onAcknowledgeReport: () -> Void
    
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
        let fills = (vehicle.fillUps ?? []).map(VehicleEvent.fillUp), svcs = (vehicle.services ?? []).map(VehicleEvent.service)
        return (fills + svcs).sorted { $0.date > $1.date }
    }
    
    var displayedEvents: [VehicleEvent] {
        timelineEvents.filter { selectedLogTab == .fuel ? (String(describing: $0).contains("fillUp")) : (String(describing: $0).contains("service")) }
    }
    
    /// Insets kept out of the map's usable area: room for the floating controls
    /// at the top, and a little breathing room above the sheet.
    private static let mapTopInset: CGFloat = 80
    private static let mapBottomMargin: CGFloat = 24

    /// How much of the screen the bottom sheet currently covers. `PresentationDetent`
    /// doesn't expose its fraction, so map the known detents back to their values.
    private var sheetFraction: CGFloat {
        if sheetDetent == .large { return 0.92 }
        if sheetDetent == .fraction(0.65) { return 0.65 }
        return 0.35
    }

    var body: some View {
        GeometryReader { proxy in
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if isMapReady {
                // Keep the map's usable area in step with the sheet: a fixed inset
                // let the "fit all pins" region extend underneath the sheet, so
                // pins bunched up along the bottom edge and out of sight.
                let sheetHeight = proxy.size.height * sheetFraction
                FlightPathMap(events: displayedEvents, showLines: false, mapStyle: useSatellite ? .imagery : .standard, bottomPadding: sheetHeight + Self.mapBottomMargin, selectedItemID: $selectedEventID, position: $mapPosition, topPadding: Self.mapTopInset, horizontalPadding: 40)
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
        .onAppear {
            locationManager.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.3)) { isMapReady = true }
            }
        }
        .onChange(of: isMapReady) { _, ready in
            if ready {
                let mapEvents = displayedEvents.filter({ $0.coordinate != nil })
                if mapEvents.isEmpty {
                    if let loc = locationManager.location {
                        mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000))
                    } else {
                        locationManager.onLocationUpdate = { loc in
                            mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000))
                            locationManager.onLocationUpdate = nil
                        }
                    }
                } else if mapEvents.count == 1, let coord = mapEvents.first?.coordinate {
                    mapPosition = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 5000, longitudinalMeters: 5000))
                }
            }
        }
        .sheet(isPresented: .constant(true)) {
            DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: $sheetDetent)
                .presentationDetents([.fraction(0.35), .fraction(0.65), .large], selection: $sheetDetent)
                .presentationDragIndicator(.visible).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.65))).interactiveDismissDisabled()
                .presentationBackground {
                    if #available(iOS 26.0, *) {
                        if colorScheme == .dark {
                            Color.black.opacity(0.5).glassEffect(.clear, in: Rectangle())
                        } else {
                            Color.clear.glassEffect(.clear, in: Rectangle())
                        }
                    } else {
                        colorScheme == .dark ? Color(uiColor: .systemBackground).opacity(0.85) : Color(uiColor: .systemGroupedBackground)
                    }
                }
        }
        .onChange(of: sheetDetent) { _, _ in refitMap(containerHeight: proxy.size.height) }
        }
    }

    /// Re-frames the map whenever the sheet resizes, so the pins stay centred in
    /// whatever strip of map is still visible. Runs for every detent, including
    /// returning to the smallest one, which previously never re-fitted.
    ///
    /// Sets an explicit region rather than reassigning `.automatic`: assigning the
    /// same value isn't seen as a change, so the fit would never recompute.
    private func refitMap(containerHeight: CGFloat) {
        let coords = displayedEvents.compactMap(\.coordinate)
        guard !coords.isEmpty, containerHeight > 0 else { return }

        let bottomInset = containerHeight * sheetFraction + Self.mapBottomMargin
        let visibleHeight = containerHeight - Self.mapTopInset - bottomInset
        // Near-fully covered: too little map left to aim at, and fitting into a
        // sliver blows the zoom out to nothing. Leave the camera as it is.
        guard visibleHeight > 120 else { return }

        withAnimation(.easeInOut(duration: 0.5)) {
            mapPosition = .region(region(fitting: coords))
        }
    }

    /// The smallest region containing every coordinate, with margin so pins
    /// aren't flush against the edges.
    ///
    /// Deliberately does not offset the centre to account for the sheet: the
    /// map's `safeAreaPadding` already biases the camera into the visible strip,
    /// and compensating again over-corrects far enough to push pins off screen.
    private func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(center: coords[0], latitudinalMeters: 5000, longitudinalMeters: 5000)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        // Floor the span so a single pin (or several very close together) doesn't
        // zoom to street level.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.05)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

enum LogTabChoice: String, CaseIterable, Identifiable { case fuel = "Fuel Logs", service = "Service Logs"; var id: String { rawValue } }

/// Identifiable wrapper so the share sheet can be presented with `.sheet(item:)`.
struct VehicleShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Presents the system share sheet for the given items.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Dashboard Bottom Sheet
struct DashboardSheetContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) var colorScheme
    let vehicle: Vehicle
    let allVehicles: [Vehicle]
    let events: [VehicleEvent]
    let onSelectVehicle: (UUID) -> Void
    let newReportMonth: Date?
    let onAcknowledgeReport: () -> Void
    @Binding var selectedLogTab: LogTabChoice
    @Binding var sheetDetent: PresentationDetent
    
    @State private var showingAddFillUp = false
    @State private var fillUpEntryMode: FillUpEntryMode = .fuel
    @State private var showingAddService = false
    @State private var showingTrips = false
    @State private var showingSettings = false
    @State private var showingArchivedVehicles = false
    @State private var showingAddVehicle = false
    @State private var showingDeleteConfirmation = false
    @State private var showingCharts = false
    @State private var showingMonthlyReport = false
    @State private var monthlyReportMonth = Date()
    @State private var isDropdownOpen = false
    @State private var eventToEdit: VehicleEvent?
    @State private var vehicleToEdit: Vehicle?
    @State private var vehicleShareItem: VehicleShareItem?
    
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                VStack(spacing: 0) {
                    FlightyStatsGrid(vehicle: vehicle, selectedTab: selectedLogTab).padding(.horizontal, 24).padding(.bottom, 24)
                    quickActionButtons
                    if vehicle.isMaintenanceDue { MaintenanceAlertView(vehicle: vehicle).padding(.horizontal, 24).padding(.bottom, 16) }
                    
                    if !(vehicle.fillUps?.isEmpty ?? true) || !(vehicle.services?.isEmpty ?? true) {
                        Button {
                            showingCharts = true
                        } label: {
                            HStack {
                                Image(systemName: "chart.xyaxis.line")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                Text("View Trends & Charts")
                                    .font(.headline.weight(.bold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .applyLiquidGlassOrBackground(cornerRadius: 16)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    
                    Picker("Log View", selection: $selectedLogTab) { ForEach(LogTabChoice.allCases) { tab in Text(tab.rawValue).tag(tab) } }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search logs...", text: $searchText)
                    }
                    .padding(10)
                    .applyLiquidGlassOrBackground(cornerRadius: 12, fallbackColor: .tertiarySystemGroupedBackground)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    
                    logViewArea
                }
            }
        }
        .overlay(alignment: .topLeading) { dropdownMenu }
        .sheet(isPresented: $showingAddFillUp) { NavigationStack { AddFillUpView(vehicle: vehicle, entryMode: fillUpEntryMode) } }
        .sheet(isPresented: $showingAddService) { NavigationStack { AddServiceView(vehicle: vehicle) } }
        .sheet(item: $eventToEdit) { ev in NavigationStack { switch ev { case .fillUp(let f): AddFillUpView(vehicle: vehicle, editingFillUp: f); case .service(let s): AddServiceView(vehicle: vehicle, editingService: s) } } }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() } }
        .sheet(item: $vehicleToEdit) { v in NavigationStack { AddVehicleView(editingVehicle: v) } }
        .sheet(isPresented: $showingArchivedVehicles) { ArchivedVehiclesView() }
        .sheet(isPresented: $showingCharts) { VehicleChartsView(vehicle: vehicle) }
        .alert("Delete \(vehicle.name)?", isPresented: $showingDeleteConfirmation) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { deleteEvent(vehicle) } } message: { Text("This will permanently delete this vehicle and all logs.") }
        .fullScreenCover(isPresented: $showingTrips) { NavigationStack { TripsListView(vehicle: vehicle) } }
        .sheet(isPresented: $showingMonthlyReport) { NavigationStack { MonthlyReportView(month: monthlyReportMonth, isModal: true) } }
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
                Button {
                    if let month = newReportMonth {
                        onAcknowledgeReport()
                        monthlyReportMonth = month
                        showingMonthlyReport = true
                    } else {
                        showingTrips = true
                    }
                } label: {
                    Image(systemName: "map.fill").font(.system(size: 20))
                        .foregroundColor(newReportMonth != nil ? Color.accentColor : .primary)
                        .frame(width: 44, height: 44)
                        .background(newReportMonth != nil ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemFill), in: Circle())
                        .overlay {
                            if newReportMonth != nil {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2).shadow(color: .accentColor.opacity(0.9), radius: 5)
                            }
                        }
                        .symbolEffect(.pulse, options: .repeating, isActive: newReportMonth != nil)
                }.accessibilityIdentifier("TripsButton")
                Button { shareVehicleForLogging() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundColor(.primary).frame(width: 44, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
                    .accessibilityIdentifier("ShareVehicleButton")
                    .accessibilityLabel("Share \(vehicle.name) for logging")
                Button { showingSettings = true } label: { Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(.primary).frame(width: 44, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
            }
        }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
    }
    
    /// Creates a "share for logging" link for the current vehicle and presents
    /// the system share sheet. A borrower opens the link in the App Clip, logs a
    /// fill-up, and it syncs back into this vehicle via the relay.
    private func shareVehicleForLogging() {
        let token = UUID()
        let record = ShareToken(token: token, vehicleID: vehicle.id, vehicleName: vehicle.name)
        modelContext.insert(record)
        try? modelContext.save()

        // Start listening for submissions on this token (near-instant import).
        SharedLoggingImporter.shared.registerSubscription(for: token)

        let descriptor = SharedVehicleDescriptor(
            token: token,
            vehicleID: vehicle.id,
            name: vehicle.name,
            make: vehicle.make,
            model: vehicle.model,
            year: vehicle.year,
            fuelTypeRaw: vehicle.fuelTypeRaw,
            fuelUnitRaw: vehicle.fuelUnitRaw,
            odometerUnitRaw: vehicle.odometerUnitRaw,
            currencyRaw: vehicle.currencyRaw
        )
        vehicleShareItem = VehicleShareItem(url: descriptor.shareURL)
    }

    private var quickActionButtons: some View {
        HStack(spacing: 12) {
            fuelQuickAction
            Button { showingAddService = true } label: { 
                Label("Service", systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .foregroundColor(.white) 
            }.accessibilityIdentifier("QuickAddService")
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }
    
    @ViewBuilder private var fuelQuickAction: some View {
        if vehicle.fuelType == .plugInHybrid {
            Menu {
                Button {
                    fillUpEntryMode = .fuel
                    showingAddFillUp = true
                } label: {
                    Label("Gas", systemImage: "fuelpump.fill")
                }
                Button {
                    fillUpEntryMode = .charge
                    showingAddFillUp = true
                } label: {
                    Label("Charge", systemImage: "bolt.car.fill")
                }
            } label: {
                fuelPillLabel
            }
            .accessibilityIdentifier("QuickAddFuel")
        } else {
            Button {
                showingAddFillUp = true
            } label: {
                fuelPillLabel
            }
            .accessibilityIdentifier("QuickAddFuel")
        }
    }

    private var fuelPillLabel: some View {
        Label(vehicle.fuelType == .electric ? "Charge" : (vehicle.fuelType == .plugInHybrid ? "Fuel / Charge" : "Fuel"), systemImage: vehicle.fuelType == .electric ? "bolt.car.fill" : "fuelpump.fill")
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(vehicle.fuelType == .electric ? Color.red : (vehicle.fuelType == .diesel ? Color.green : Color.blue), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .foregroundColor(.white)
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
                    Text(searchText.isEmpty ? (selectedLogTab == .fuel ? "No logs yet." : "No service logs yet.") : "No logs match your search.")
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
    
    private func deleteEvent(_ vehicleToDelete: Vehicle) {
        modelContext.delete(vehicleToDelete)
        try? modelContext.save()
    }
    
    private func deleteEvent(_ event: VehicleEvent) {
        switch event { 
        case .fillUp(let f): 
            vehicle.fillUps?.removeAll(where: { $0.id == f.id })
            modelContext.delete(f)
        case .service(let s): 
            vehicle.services?.removeAll(where: { $0.id == s.id })
            modelContext.delete(s)
        }
        
        // Force UI update
        let temp = vehicle.fuelUnitRaw
        vehicle.fuelUnitRaw = ""
        vehicle.fuelUnitRaw = temp
        
        try? modelContext.save()
        if UserDefaults.standard.bool(forKey: "smartRemindersEnabled") {
            SmartRemindersManager.shared.updateReminders(for: vehicle)
        }
    }
}

struct MaintenanceAlertView: View {
    let vehicle: Vehicle
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("MAINTENANCE DUE").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                if vehicle.fuelType == .electric {
                    Text("Time for a routine inspection.").font(.body).foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("Time for an oil change & inspection.").font(.body).foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()
        }
        .padding()
        .background(Color.red, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}


