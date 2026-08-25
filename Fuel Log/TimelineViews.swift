// xcode: set sdk=iOS

//
//  TimelineViews.swift
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

// MARK: - Flight Path Map
struct FlightPathMap: View {
    let events: [VehicleEvent]
    let showLines: Bool
    let mapStyle: MapStyle
    let bottomPadding: CGFloat
    @Binding var selectedItemID: UUID?
    @Binding var position: MapCameraPosition
    var minDistance: CLLocationDistance = 0
    var topPadding: CGFloat = 0
    var horizontalPadding: CGFloat = 0
    /// Opt in for short map cards, where a pin fitted to the edge would have its
    /// title label clipped. Off by default because these insets also push
    /// MapKit's own compass and scale bar inward, which looks wrong on
    /// full-screen maps.
    var reservesRoomForAnnotationLabels: Bool = false

    var body: some View {
        Map(position: $position, bounds: minDistance > 0 ? MapCameraBounds(minimumDistance: minDistance) : nil, selection: $selectedItemID) {
            if showLines { MapPolyline(coordinates: events.compactMap(\.coordinate)).stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)) }
            ForEach(events.filter { $0.coordinate != nil }.sorted { lhs, rhs in (lhs.icon == "fuelpump.fill" || lhs.icon == "bolt.car.fill") == (rhs.icon == "fuelpump.fill" || rhs.icon == "bolt.car.fill") ? lhs.date < rhs.date : (rhs.icon == "fuelpump.fill" || rhs.icon == "bolt.car.fill") }) { event in
                Annotation(event.title, coordinate: event.coordinate!) {
                    Image(systemName: event.icon).font(.system(size: 14, weight: .bold)).foregroundColor(.white).frame(width: 32, height: 32).background(event.color, in: Circle()).overlay(Circle().stroke(Color.white, lineWidth: 2)).shadow(radius: 3, y: 2)
                }.tag(event.id)
            }
            if #available(iOS 17.0, *) { UserAnnotation() }
        }
        .mapStyle(mapStyle)
        .safeAreaPadding(insets)
    }

    /// Insets steer where the camera frames content. When reserving room for
    /// annotation labels they're floored so a pin fitted to the edge keeps its
    /// title on screen.
    private var insets: EdgeInsets {
        guard reservesRoomForAnnotationLabels else {
            return EdgeInsets(top: topPadding, leading: horizontalPadding, bottom: bottomPadding, trailing: horizontalPadding)
        }
        return EdgeInsets(
            top: max(topPadding, Self.minimumAnnotationInset),
            leading: max(horizontalPadding, Self.minimumAnnotationInset),
            bottom: max(bottomPadding, Self.minimumAnnotationLabelInset),
            trailing: max(horizontalPadding, Self.minimumAnnotationInset)
        )
    }

    /// Half the 32pt marker plus a little slack.
    private static let minimumAnnotationInset: CGFloat = 28
    /// Marker plus the title label that draws underneath it.
    private static let minimumAnnotationLabelInset: CGFloat = 46
}

// MARK: - Stats Grid
struct FlightyStatsGrid: View {
    let vehicle: Vehicle
    let selectedTab: LogTabChoice
    
    var body: some View {
        HStack(spacing: 12) {
            FlightyStatBox(value: vehicle.lastOdometer != nil ? "\(Int(vehicle.totalDistanceLogged).formatted())" : "-", unit: vehicle.odometerUnit.rawValue.lowercased(), alignment: selectedTab == .service ? .center : .leading)
            
            let isFuelStat = selectedTab != .service
            if isFuelStat { FlightyStatBox(value: vehicle.averageEfficiency != nil ? String(format: "%.1f", vehicle.averageEfficiency!) : "-", unit: vehicle.efficiencyUnit.rawValue, alignment: .center) }
            
            FlightyStatBox(value: (isFuelStat ? vehicle.totalFuelCost : vehicle.totalServiceCost) > 0 ? (isFuelStat ? vehicle.totalFuelCost : vehicle.totalServiceCost).formatted(.currency(code: vehicle.currencyRaw)) : "-", unit: "total \(isFuelStat ? (vehicle.fuelType == .electric ? "energy" : "fuel") : "service") cost", alignment: selectedTab == .service ? .center : .trailing)
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
    /// Liquid Glass looks right over the dashboard's map/sheet, but washes out on
    /// flat pages like the trip detail. Those callers set this to false.
    var useGlassBackground: Bool = true
    
    var dateAndTypeText: String {
        var parts = [event.date.formatted(date: .abbreviated, time: .omitted)]
        switch event {
        case .service(let s):
            parts.append(s.type.rawValue)
        case .fillUp(let f):
            // Surface the grade alongside the row's efficiency figure, so a
            // lower MPG on an E85 tank is self-explanatory. Falls back to the
            // vehicle's usual grade for entries logged before grade tracking.
            if let gradeName = f.effectiveGradeName { parts.append(gradeName) }
        }
        return parts.joined(separator: " • ")
    }
    
    var tripDistanceText: String? {
        if case .fillUp = event, let odo = event.odometer, let prev = previousOdometer, odo > prev {
            return "\(Int(odo - prev).formatted()) \(distanceUnit == "miles" ? "mile" : "km") trip"
        }
        return nil
    }
    
    var tripEfficiencyText: String? {
        if case .fillUp(let f) = event, let odo = event.odometer, let prev = previousOdometer, odo > prev, f.isFullTank {
            let dist = odo - prev
            let vol = f.volume
            guard vol > 0 else { return nil }
            if f.unit == .kwh {
                let unitString = (event.vehicle?.odometerUnit == .kilometers) ? "km/kWh" : "mi/kWh"
                return String(format: "%.1f %@", dist / vol, unitString)
            }
            let effUnit = event.vehicle?.efficiencyUnit ?? .mpgUS
            let vehicle = event.vehicle
            let val = EfficiencyConverter.convert(distance: dist, odometerUnit: vehicle?.odometerUnit ?? .miles, volume: vol, fuelUnit: vehicle?.fuelUnit ?? .gallons, to: effUnit)
            
            let unitString: String
            switch effUnit {
            case .mpgUS: unitString = "MPG (US)"
            case .mpgUK: unitString = "MPG (UK)"
            case .l100km: unitString = "L/100km"
            case .kmPerLitre: unitString = "km/L"
            case .miPerKWh: unitString = "mi/kWh"
            case .kmPerKWh: unitString = "km/kWh"
            }
            
            return String(format: "%.1f %@", val, unitString)
        }
        return nil
    }
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Color(uiColor: .separator)).frame(width: 3)
                ZStack { Circle().fill(event.color).frame(width: 28, height: 28); Image(systemName: event.icon).font(.system(size: 14, weight: .bold)).foregroundColor(.white) }.padding(.vertical, 8)
                Rectangle().fill(isLast ? Color.clear : Color(uiColor: .separator)).frame(width: 3)
            }.frame(width: 44)
            
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(dateAndTypeText)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if let odo = event.odometer {
                        Text("\(Int(odo).formatted()) \(distanceUnit)")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 6) {
                    Text(event.cost, format: .currency(code: event.vehicle?.currencyRaw ?? "USD"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    
                    if let mpgText = tripEfficiencyText {
                        Text(mpgText)
                            .font(.body.weight(.bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                    if let tripText = tripDistanceText {
                        Text(tripText)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding()
            .applyLiquidGlassOrBackground(cornerRadius: 24, useGlass: useGlassBackground)
            .padding(.vertical, 6)
            .padding(.trailing, 24)
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
        ((vehicle.fillUps ?? []).map(VehicleEvent.fillUp) + (vehicle.services ?? []).map(VehicleEvent.service)).filter { ev in
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
                Section("Log Information") { LabeledContent("Location", value: event.title); LabeledContent("Date", value: event.date.formatted(date: .abbreviated, time: .shortened)); LabeledContent("Cost", value: event.cost.formatted(.currency(code: event.vehicle?.currencyRaw ?? "USD"))); if let odo = event.odometer { LabeledContent("Odometer", value: "\(Int(odo).formatted())") } }
                switch event {
                case .fillUp(let f):
                    Section("Fuel Details") { LabeledContent("Volume", value: "\(f.volume) \(f.unit.rawValue)"); if let gradeName = f.effectiveGradeName { LabeledContent("Fuel Grade", value: gradeName) };LabeledContent("Price per Unit", value: f.pricePerUnit.formatted(.currency(code: event.vehicle?.currencyRaw ?? "USD"))); if f.isFullTank { LabeledContent("Fill Type", value: "Full Tank") } }
                    if !f.notes.isEmpty { Section("Notes") { Text(f.notes).font(.body) } }
                case .service(let s):
                    Section("Service Details") { LabeledContent("Type", value: s.type.rawValue) }
                    if !s.notes.isEmpty { Section("Notes") { Text(s.notes).font(.body) } }
                }
                
                if let rData = event.receiptData, let uiImage = UIImage(data: rData) {
                    Section("Receipt") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                    }
                }
            }
            .navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(.headline) } }
        }
    }
}


