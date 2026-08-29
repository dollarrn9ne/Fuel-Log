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
    /// Zoom chosen when the pins last changed, held steady while the sheet moves.
    @State private var fittedSpan: MKCoordinateSpan?
    @State private var sheetDetent: PresentationDetent = .fraction(0.35)
    @State private var selectedLogTab: LogTabChoice = .fuel
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var isMapReady = false
    @StateObject private var menuCommands = MenuCommandBus.shared
    @State private var layoutMode: DashboardLayout = .bottomSheet
    /// Settled height of the portrait card, as a fraction of the screen.
    @State private var cardHeightFraction: CGFloat = 0.34

    /// Where the dashboard content sits relative to the map.
    private enum DashboardLayout { case bottomSheet, sidePanel, bottomPanel }
    
    var timelineEvents: [VehicleEvent] {
        let fills = (vehicle.fillUps ?? []).map(VehicleEvent.fillUp), svcs = (vehicle.services ?? []).map(VehicleEvent.service)
        return (fills + svcs).sorted { $0.date > $1.date }
    }
    
    var displayedEvents: [VehicleEvent] {
        timelineEvents.filter { selectedLogTab == .fuel ? (String(describing: $0).contains("fillUp")) : (String(describing: $0).contains("service")) }
    }
    
    /// Insets kept out of the map's usable area: room for the floating controls
    /// at the top, and a little breathing room above the sheet.
    /// Clearance below the floating map buttons, used only in the camera maths.
    /// It is deliberately not a map inset: insets also relocate MapKit's compass
    /// and scale bar, and an animated one caused the earlier layout gaps.
    private static let mapTopMargin: CGFloat = 80

    /// One curve shared by the camera move and the map's inset change. They must
    /// match: animating the camera while the usable area snaps instantly is what
    /// made resizing the sheet feel abrupt. `smooth` eases out without the fast
    /// middle of `easeInOut`, which reads badly on a zoom.
    private static let mapReframeAnimation: Animation = .smooth(duration: 0.9)

    /// Full screen height including the safe areas, which `proxy.size` omits.
    private func fullHeight(_ proxy: GeometryProxy) -> CGFloat {
        proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
    }

    /// MapKit leaves its own margin above the inset before drawing the Apple Maps
    /// attribution, which left it floating well clear of the sheet. Trimming the
    /// inset by roughly that margin settles it just above the sheet's top edge.
    private static let attributionDrop: CGFloat = 36

    /// Bottom inset applied to the map, sized so the attribution clears the sheet
    /// at its resting height without sitting any higher than it needs to.
    private func attributionInset(_ containerHeight: CGFloat) -> CGFloat {
        // The card floats clear of the bottom edge, so the attribution has to
        // clear the card *and* its margins rather than a fraction of the screen.
        if layoutMode == .bottomPanel {
            return containerHeight * cardHeightFraction + Self.bottomCardMargin * 2
        }
        return max(containerHeight * restingOccludedFraction - Self.attributionDrop, 0)
    }

    /// The part of the map the camera actually frames into. The bottom inset that
    /// keeps the attribution clear of the sheet also shortens the area MapKit fits
    /// a region to, so every camera calculation measures against this rather than
    /// the full height.
    private func usableHeight(_ containerHeight: CGFloat) -> CGFloat {
        max(containerHeight - attributionInset(containerHeight), 1)
    }

    /// The smallest detent offered, and the app's default.
    private static let smallestSheetFraction: CGFloat = 0.35
    /// The tallest detent the map still pans for. Beyond this so little map is
    /// left that panning is skipped, so it doesn't constrain the zoom.
    private static let tallestPannedSheetFraction: CGFloat = 0.65

    /// How much of the screen the bottom sheet currently covers. `PresentationDetent`
    /// doesn't expose its fraction, so map the known detents back to their values.
    private var sheetFraction: CGFloat {
        if sheetDetent == .large { return 0.92 }
        if sheetDetent == .fraction(0.65) { return 0.65 }
        return Self.smallestSheetFraction
    }

    /// Width the side panel needs before it earns its place: 420pt of panel plus
    /// enough map beside it to still be worth looking at. Sits between iPad
    /// portrait (1024pt, card) and iPad mini landscape (1133pt, panel).
    private static let sidePanelMinimumWidth: CGFloat = 1080
    /// Extra shrink required to give the side panel up once it's shown, so a
    /// window parked on the threshold doesn't flicker between layouts.
    private static let layoutSwitchHysteresis: CGFloat = 60
    private static let layoutChangeAnimation: Animation = .smooth(duration: 0.3)

    /// Which arrangement suits the window.
    ///
    /// Two layouts on iPad, one on iPhone - never three. Gating the sheet on the
    /// size class meant a narrowed iPad window became compact and swapped to the
    /// sheet, so resizing walked card -> sheet on top of card -> panel. Three
    /// styles for one drag.
    ///
    /// Keyed on the idiom rather than the size class for exactly that reason: a
    /// narrow iPad window is still an iPad, and the card suits it. The sheet is
    /// kept for iPhone, where its detents are tuned and the shape is right.
    ///
    /// The panel-vs-card choice is width, not the aspect ratio it once compared.
    /// Aspect flipped a near-square window on a tiny drag, and near-square is
    /// exactly where windows get parked.
    private func layout(_ proxy: GeometryProxy) -> DashboardLayout {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .bottomSheet }
        let threshold = layoutMode == .sidePanel
            ? Self.sidePanelMinimumWidth - Self.layoutSwitchHysteresis
            : Self.sidePanelMinimumWidth
        return proxy.size.width >= threshold ? .sidePanel : .bottomPanel
    }

    /// Portrait shows a card floating clear of the edges with the map visible all
    /// round it, the way Maps does on iPad. A bar pinned across the full width is
    /// the thing that reads as a phone layout enlarged.
    /// Resting height: enough for the header, stats, actions and the log tabs.
    private static let bottomCardRestingHeightFraction: CGFloat = 0.34
    /// Hard stop at half the screen. Past that the card stops reading as
    /// something floating over the map and becomes a panel covering it again.
    private static let bottomCardMaxHeightFraction: CGFloat = 0.5
    private static let bottomCardWidthFraction: CGFloat = 0.6
    private static let bottomCardMinWidth: CGFloat = 360
    private static let bottomCardMaxWidth: CGFloat = 560
    private static let bottomCardMargin: CGFloat = 20

    /// Share of the height covered by whatever sits over the map's bottom.
    private var occludedFraction: CGFloat {
        layoutMode == .bottomPanel ? cardHeightFraction : sheetFraction
    }

    /// The occlusion at rest, which is what the attribution has to clear.
    private var restingOccludedFraction: CGFloat {
        layoutMode == .bottomPanel ? cardHeightFraction : Self.smallestSheetFraction
    }

    /// The most the map is ever covered, which is what the zoom keeps pins clear
    /// of. Both layouts stop panning past the same fraction.
    private var tallestOccludedFraction: CGFloat { Self.tallestPannedSheetFraction }

    /// Fixed on purpose. A draggable edge meant the map's trailing inset changed
    /// on every gesture update, and re-framing the camera that often made the
    /// whole screen jitter.
    private static let panelWidth: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if isMapReady {
                // Keep the map's usable area in step with the sheet: a fixed inset
                // let the "fit all pins" region extend underneath the sheet, so
                // pins bunched up along the bottom edge and out of sight.
                //
                // Detent fractions are of the whole screen, so measure against
                // the full height. `proxy.size` excludes the safe area, and
                // pinning the map to that shorter height left a band of
                // background along the bottom edge.
                // A bottom inset the height of the resting sheet. MapKit draws the
                // required Apple Maps attribution in the bottom-left of the map's
                // safe area, and with no inset the sheet sat on top of it, which
                // App Review rejects. The inset lifts it clear.
                //
                // Constant rather than tracking the detent: an inset that changed
                // as the sheet moved re-framed the camera mid-animation, which is
                // what made resizing feel abrupt. The camera maths below accounts
                // for this one fixed value.
                FlightPathMap(events: displayedEvents, showLines: false, mapStyle: useSatellite ? .imagery : .standard,
                              bottomPadding: layout(proxy) == .sidePanel ? 0 : attributionInset(fullHeight(proxy)),
                              selectedItemID: $selectedEventID, position: $mapPosition,
                              // Beside the map, the panel occludes the trailing edge
                              // rather than the bottom, so the attribution and the
                              // camera both need the inset over there instead.
                              trailingPadding: layout(proxy) == .sidePanel ? Self.panelWidth : 0,
                              onCameraChange: { region in
                    adoptUserZoom(region.span)
                })
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
                } else {
                    // Establish the zoom once, so later sheet drags only pan.
                    refitMap(containerHeight: fullHeight(proxy), refreshZoom: true)
                }
            }
        }
        // The pins themselves changed, so a fresh zoom is warranted.
        .onChange(of: vehicle.id) { _, _ in refitMap(containerHeight: fullHeight(proxy), refreshZoom: true) }
        .onChange(of: selectedLogTab) { _, _ in refitMap(containerHeight: fullHeight(proxy), refreshZoom: true) }
        // Mirrored into state as well, so the camera maths doesn't need the proxy
        // threaded through every call.
        .overlay(alignment: .trailing) {
            if layout(proxy) == .sidePanel { sidePanel }
        }
        .overlay(alignment: .bottomLeading) {
            if layout(proxy) == .bottomPanel { bottomPanel(proxy) }
        }
        .onAppear { layoutMode = layout(proxy) }
        .onChange(of: layout(proxy)) { _, mode in
            // Animated so a resize crossing the threshold reads as the panel
            // moving rather than one layout being swapped for another.
            withAnimation(Self.layoutChangeAnimation) { layoutMode = mode }
            // Deferred a turn on purpose. Reading layoutMode straight after
            // writing it still yields the old value, so refitMap would pick the
            // previous layout's branch - rotating to landscape framed the pins as
            // though the portrait panel were still covering the bottom.
            Task { refitMap(containerHeight: fullHeight(proxy), refreshZoom: true) }
        }
        .sheet(isPresented: .constant(layout(proxy) == .bottomSheet)) {
            DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: $sheetDetent)
                .presentationDetents([.fraction(0.35), .fraction(0.65), .large], selection: $sheetDetent)
                .presentationDragIndicator(.visible).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.65))).interactiveDismissDisabled()
                .presentationBackground { panelBackground(in: Rectangle()) }
        }
        .onChange(of: sheetDetent) { _, _ in
            refitMap(containerHeight: fullHeight(proxy))
        }
        // Menu commands whose state lives on this view.
        .onChange(of: menuCommands.pending) { _, command in
            switch command {
            case .showFuelLogs: selectedLogTab = .fuel
            case .showServiceLogs: selectedLogTab = .service
            case .toggleSatellite: useSatellite.toggle()
            default: return
            }
            if let command { menuCommands.consume(command) }
        }
        }
    }

    /// Re-frames the map whenever the sheet resizes, so the pins stay centred in
    /// whatever strip of map is still visible. Runs for every detent, including
    /// returning to the smallest one, which previously never re-fitted.
    ///
    /// Sets an explicit region rather than reassigning `.automatic`: assigning the
    /// same value isn't seen as a change, so the fit would never recompute.
    /// Slides the camera so the pins sit in the strip the sheet leaves visible.
    ///
    /// The zoom is held constant on purpose. Re-fitting the span meant the same
    /// pins had to squeeze into a much shorter strip, which is a large camera
    /// move no easing curve can make feel gentle. Panning is a small move, so it
    /// reads as smooth. Pass `refreshZoom` when the content itself changed and a
    /// new zoom is warranted.
    /// Full-height panel pinned to the trailing edge. Nothing is hidden behind a
    /// detent here, so every row is reachable by scrolling.
    private var sidePanel: some View {
        DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: .constant(.large))
            .frame(width: Self.panelWidth)
            .frame(maxHeight: .infinity)
            .background {
                // Only the glass runs to the top and bottom edges. Letting the
                // whole panel ignore the safe area would slide the header under
                // the status bar, but leaving the background inside it stranded
                // a strip of map above and below, so the panel looked clipped.
                panelBackground(in: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28, style: .continuous), frosted: true)
                    .ignoresSafeArea(edges: .vertical)
            }
            .transition(.move(edge: .trailing))
    }

    /// The treatment `presentationBackground` gives the sheet, so the hand-built
    /// panels match it. `.regularMaterial` was far more opaque than the sheet's
    /// clear glass: the portrait panel came out a washed-out green where the
    /// iPhone picks up the map vividly, and the side panel came out flat grey.
    ///
    /// - Parameter frosted: true for the hand-built panels, false for the sheet.
    ///   Clear glass works for the sheet because the system dims and blurs behind
    ///   a presentation as well; an inline panel gets none of that, so the same
    ///   setting left the map showing through almost unimpeded - street labels
    ///   reading straight through the stats row. Frosted still takes the map's
    ///   colour, it just blurs enough to stay legible over dense map detail.
    @ViewBuilder
    private func panelBackground(in shape: some Shape, frosted: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if colorScheme == .dark {
                Color.black.opacity(0.5).glassEffect(frosted ? .regular : .clear, in: shape)
            } else {
                Color.clear.glassEffect(frosted ? .regular : .clear, in: shape)
            }
        } else {
            (colorScheme == .dark ? Color(uiColor: .systemBackground).opacity(0.85) : Color(uiColor: .systemGroupedBackground))
                .clipShape(shape)
        }
    }

    /// The portrait card: floats clear of the edges with the map visible around
    /// it, rather than spanning the width and pinning to the bottom.
    ///
    /// Resizable by the pull bar between its resting height and half the screen.
    private func bottomPanel(_ proxy: GeometryProxy) -> some View {
        let full = fullHeight(proxy)
        let cardShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        // Clamped to what's actually there as well as to the preferred range: a
        // narrowed iPad window can be slimmer than the 360pt floor, and the card
        // should shrink with it rather than overflow the edges.
        let available = max(proxy.size.width - Self.bottomCardMargin * 2, 1)
        let preferred = min(max(proxy.size.width * Self.bottomCardWidthFraction, Self.bottomCardMinWidth), Self.bottomCardMaxWidth)
        let width = min(preferred, available)
        return VStack(spacing: 0) {
            bottomCardPullBar(full: full)
            DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: .constant(.large))
        }
            .frame(width: width, height: full * cardHeightFraction)
            .background { panelBackground(in: cardShape, frosted: true) }
            .clipShape(cardShape)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            // Even margin on every side. The overlay measures against the full
            // screen, since a sibling in the ZStack ignores the safe area so the
            // map can bleed to the edges - so this is a true 20pt from each
            // screen edge, which clears the home indicator on its own.
            .padding(Self.bottomCardMargin)
            .animation(.smooth(duration: 0.28), value: cardHeightFraction)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Drags the card between its resting height and the half-screen ceiling.
    ///
    /// Snaps to the nearer height as the finger passes the midpoint rather than
    /// tracking it point for point. Every distinct height re-lays out the whole
    /// card - the log list included - and re-renders the glass at a new size, so
    /// following the finger meant a layout pass per frame, which is what the
    /// jitter was. Quantising the height only reduced the count; snapping makes
    /// it one pass per drag, and the animation covers the change.
    private func bottomCardPullBar(full: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.6))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let target = (full * cardHeightFraction - value.translation.height) / full
                        let snapped = Self.nearestCardFraction(to: target)
                        // Assigning unconditionally would restart the animation on
                        // every update once the finger is past the midpoint.
                        guard snapped != cardHeightFraction else { return }
                        cardHeightFraction = snapped
                    }
                    .onEnded { _ in
                        // Deferred so refitMap sees the fraction just written.
                        Task { refitMap(containerHeight: full) }
                    }
            )
            .accessibilityLabel("Resize card")
    }

    private static func nearestCardFraction(to fraction: CGFloat) -> CGFloat {
        let heights = [bottomCardRestingHeightFraction, bottomCardMaxHeightFraction]
        return heights.min { abs($0 - fraction) < abs($1 - fraction) } ?? bottomCardRestingHeightFraction
    }

    private func refitMap(containerHeight: CGFloat, refreshZoom: Bool = false) {
        let coords = displayedEvents.compactMap(\.coordinate)
        guard !coords.isEmpty, containerHeight > 0 else { return }

        if refreshZoom { fittedSpan = nil }

        // Beside the map, nothing covers the bottom, so there is no strip to pan
        // the pins into: centre them and let the trailing inset keep them clear
        // of the panel. The vertical maths below is portrait-only by design.
        if layoutMode == .sidePanel {
            let span = fittedSpan ?? sideBySideSpan(for: coords)
            fittedSpan = span
            withAnimation(Self.mapReframeAnimation) {
                mapPosition = .region(MKCoordinateRegion(center: boundingCentre(of: coords), span: span))
            }
            return
        }
        let span = fittedSpan ?? fittingSpan(for: coords, containerHeight: containerHeight)
        fittedSpan = span

        let sheetHeight = containerHeight * occludedFraction
        // Near-fully covered: nothing meaningful left to aim at, so hold still
        // rather than panning the pins away.
        guard containerHeight - Self.mapTopMargin - sheetHeight > 120 else { return }

        withAnimation(Self.mapReframeAnimation) {
            mapPosition = .region(pannedRegion(coords: coords, span: span, containerHeight: containerHeight, sheetHeight: sheetHeight))
        }
    }

    /// Records a zoom the user reached by pinching, so the next sheet drag pans
    /// from there rather than snapping back.
    ///
    /// Ignored until we've set our own zoom: this also fires for MapKit's initial
    /// automatic fit, which frames the pins against the whole view and therefore
    /// tucks the lower ones behind the sheet. Adopting that defeated the point of
    /// choosing a zoom at all.
    ///
    /// Our own programmatic pans report back too, with the span adjusted to the
    /// view's aspect ratio, so only clearly deliberate changes are taken;
    /// otherwise that adjustment would feed into the next pan and drift the zoom.
    private func adoptUserZoom(_ span: MKCoordinateSpan) {
        guard let current = fittedSpan else { return }
        let ratio = span.latitudeDelta / max(current.latitudeDelta, .leastNonzeroMagnitude)
        guard ratio < 0.9 || ratio > 1.1 else { return }
        fittedSpan = span
    }

    private func boundingCentre(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        return CLLocationCoordinate2D(latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                                      longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2)
    }

    /// Pins plus a margin. MapKit fits this into the area the panel leaves, so
    /// unlike the portrait case there is no strip ratio to correct for.
    private func sideBySideSpan(for coords: [CLLocationCoordinate2D]) -> MKCoordinateSpan {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let latSpread = (lats.max() ?? 0) - (lats.min() ?? 0)
        let lonSpread = (lons.max() ?? 0) - (lons.min() ?? 0)
        return MKCoordinateSpan(latitudeDelta: max(latSpread * 1.4, 0.05),
                                longitudeDelta: max(lonSpread * 1.4, 0.05))
    }

    /// A span containing every coordinate, floored so a single pin doesn't zoom
    /// to street level.
    ///
    /// Sized against the strip left visible at the *smallest* detent, not the
    /// whole map: since the zoom then stays put while the sheet moves, fitting
    /// the full height would leave pins tucked behind the sheet even at the
    /// default height, which is the problem this all started with.
    private func fittingSpan(for coords: [CLLocationCoordinate2D], containerHeight: CGFloat) -> MKCoordinateSpan {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        }
        // Size against the *narrowest* strip we still pan for, so the pins stay
        // on screen with the sheet raised as well as at rest. Sizing to the
        // default height fitted more tightly but hid pins once the sheet grew.
        let narrowestStrip = max(containerHeight - Self.mapTopMargin - containerHeight * tallestOccludedFraction, 1)
        // The camera spans the usable area, so zoom out by however much taller
        // that is than the strip, leaving a margin so pins avoid the edges.
        let scale = (usableHeight(containerHeight) / narrowestStrip) / 0.8
        return MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * scale, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.05)
        )
    }

    /// The pins' bounding box centred in the visible strip, at a fixed zoom.
    ///
    /// MapKit centres the region in the usable area, which the attribution inset
    /// ends part-way down the screen, so the camera is shifted south by whatever
    /// is left over to lift the pins into the strip the sheet leaves uncovered.
    /// At the resting detent the two nearly coincide and the shift is small.
    private func pannedRegion(coords: [CLLocationCoordinate2D], span: MKCoordinateSpan, containerHeight: CGFloat, sheetHeight: CGFloat) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let centreLat = ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2
        let centreLon = ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2

        let viewCentre = usableHeight(containerHeight) / 2
        let stripCentre = (Self.mapTopMargin + (containerHeight - sheetHeight)) / 2
        let degreesPerPoint = span.latitudeDelta / usableHeight(containerHeight)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centreLat - degreesPerPoint * (viewCentre - stripCentre), longitude: centreLon),
            span: span
        )
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
    @State private var eventToEdit: VehicleEvent?
    @State private var vehicleToEdit: Vehicle?
    @State private var vehicleShareItem: VehicleShareItem?
    
    @State private var searchText: String = ""
    @StateObject private var sheetMenuCommands = MenuCommandBus.shared

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
                        TextField("Search name, date, mileage...", text: $searchText)
                    }
                    .padding(10)
                    .applyLiquidGlassOrBackground(cornerRadius: 12, fallbackColor: .tertiarySystemGroupedBackground)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    
                    logViewArea
                }
            }
        }
        .sheet(isPresented: $showingAddFillUp) { NavigationStack { AddFillUpView(vehicle: vehicle, entryMode: fillUpEntryMode) }.roomySheetOnPad() }
        .sheet(isPresented: $showingAddService) { NavigationStack { AddServiceView(vehicle: vehicle) }.roomySheetOnPad() }
        .sheet(item: $eventToEdit) { ev in NavigationStack { switch ev { case .fillUp(let f): AddFillUpView(vehicle: vehicle, editingFillUp: f); case .service(let s): AddServiceView(vehicle: vehicle, editingService: s) } }.roomySheetOnPad() }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() }.roomySheetOnPad() }
        .sheet(item: $vehicleToEdit) { v in NavigationStack { AddVehicleView(editingVehicle: v) }.roomySheetOnPad() }
        .sheet(isPresented: $showingArchivedVehicles) { ArchivedVehiclesView().roomySheetOnPad() }
        .sheet(isPresented: $showingCharts) { VehicleChartsView(vehicle: vehicle).roomySheetOnPad() }
        .alert("Delete \(vehicle.name)?", isPresented: $showingDeleteConfirmation) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { deleteEvent(vehicle) } } message: { Text("This will permanently delete this vehicle and all logs.") }
        // A sheet that adapts to a full-screen cover when compact, rather than a
        // cover everywhere. Taking over the whole iPad for a secondary task hides
        // the map and the vehicle you were looking at; on a phone the cover is
        // still right. Declared as one presentation so the view keeps its
        // identity across a rotation rather than being torn down and rebuilt.
        .sheet(isPresented: $showingTrips) {
            NavigationStack { TripsListView(vehicle: vehicle) }
                .presentationCompactAdaptation(.fullScreenCover)
                .roomySheetOnPad()
        }
        .sheet(isPresented: $showingMonthlyReport) { NavigationStack { MonthlyReportView(month: monthlyReportMonth, isModal: true) }.roomySheetOnPad() }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
                .presentationCompactAdaptation(.fullScreenCover)
                .roomySheetOnPad()
        }
        // Menu commands that open one of this view's presentations.
        .onChange(of: sheetMenuCommands.pending) { _, command in
            switch command {
            case .showCharts: showingCharts = true
            case .showTrips: showingTrips = true
            case .showSettings: showingSettings = true
            case .showArchivedVehicles: showingArchivedVehicles = true
            default:
                // Export and report flows live in Settings; open it and let it
                // pick the action up as it appears.
                guard let command, let action = MenuCommandBus.settingsAction(for: command) else { return }
                sheetMenuCommands.pendingSettingsAction = action
                showingSettings = true
            }
            if let command { sheetMenuCommands.consume(command) }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 16) {
            // A system Menu rather than a hand-rolled overlay: it renders outside
            // the sheet, so it needs no room made for it and can't be caught up
            // in the sheet's own animation, which is what made the old one
            // stutter. The system also owns the selection tick and dismissal.
            Menu {
                // Two groups rather than four: every Section adds a divider and
                // its own padding, which is what made the menu feel airy. An
                // unlabelled Picker also avoids reserving space for a header.
                Picker("", selection: Binding(
                    get: { vehicle.id },
                    set: { onSelectVehicle($0) }
                )) {
                    ForEach(allVehicles) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                .labelsHidden()

                Section {
                    Button { vehicleToEdit = vehicle } label: { Label("Edit Vehicle...", systemImage: "pencil") }
                    Button { archiveCurrentVehicle() } label: { Label("Archive Vehicle", systemImage: "archivebox") }
                    Button { showingArchivedVehicles = true } label: { Label("Archived Vehicles", systemImage: "tray.full") }
                    Button(role: .destructive) { showingDeleteConfirmation = true } label: { Label("Delete Vehicle", systemImage: "trash") }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(vehicle.name)
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.primary)
                        // One line, shrinking only as far as 75% so a long name
                        // stays close to the surrounding type rather than
                        // becoming conspicuously small.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                    Image(systemName: "chevron.down").font(.subheadline.weight(.bold)).foregroundColor(.secondary)
                }
            }
            // The app is rounded throughout, so ask for it here too. UIKit draws
            // system menu rows and may ignore this; if the menu still renders in
            // the default face, that's the platform's call, not a missing setting.
            .fontDesign(.rounded)
            .frame(maxWidth: .infinity, alignment: .leading)
            
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
        // Strip grouping separators from the query rather than emitting a second
        // grouped spelling of every number: one normalisation here beats two
        // formatter calls per number per row.
        let separator = Locale.current.groupingSeparator ?? ","
        let lower = searchText.replacingOccurrences(of: separator, with: "").localizedLowercase
        guard !lower.isEmpty else { return baseEvents }
        return baseEvents.filter { searchHaystack(for: $0).contains(lower) }
    }

    // Reused rather than rebuilt per call. `Date.formatted` constructs a format
    // style every time, and at three dates per row it dominated the cost of
    // filtering - noticeable once a vehicle has years of history behind it.
    private static let mediumDateFormatter = dateFormatter(.medium)
    private static let longDateFormatter = dateFormatter(.long)
    private static let shortDateFormatter = dateFormatter(.short)

    private static func dateFormatter(_ style: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter
    }

    /// Everything a log row displays, lowercased and run together, so the search
    /// box matches what the user can actually see. It previously only looked at
    /// the location name, notes and service type, so searching for a date or an
    /// odometer reading - both printed right there on the row - found nothing.
    private func searchHaystack(for event: VehicleEvent) -> String {
        var parts: [String] = []

        // Several spellings of the same date, so "aug", "august 19", "8/19" and
        // "2026" all match the one entry.
        let date = event.date
        parts.append(Self.mediumDateFormatter.string(from: date))
        parts.append(Self.longDateFormatter.string(from: date))
        parts.append(Self.shortDateFormatter.string(from: date))

        switch event {
        case .fillUp(let f):
            parts.append(f.location?.name ?? "")
            parts.append(f.notes)
            parts.append(f.effectiveGradeName ?? "")
            if let odo = f.odometer { parts.append(numberSpellings(odo)) }
            parts.append(numberSpellings(f.totalCost))
            parts.append(numberSpellings(f.volume))
        case .service(let s):
            parts.append(s.location?.name ?? "")
            parts.append(s.notes)
            parts.append(s.type.rawValue)
            parts.append(numberSpellings(s.odometer))
            parts.append(numberSpellings(s.cost))
        }

        return parts.joined(separator: " ").localizedLowercase
    }

    /// Plain digits only. The query has its grouping separators stripped before
    /// comparison, so there's no need to also spell "1,300" here - and string
    /// interpolation avoids the number formatter entirely.
    private func numberSpellings(_ value: Double) -> String {
        let whole = Int(value.rounded())
        // Keep the decimals for values that have them, e.g. a 12.4 gallon fill.
        guard value != value.rounded() else { return "\(whole)" }
        return "\(whole) \(String(format: "%.2f", value))"
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
    
    /// Archives the current vehicle and moves to another, if there is one.
    private func archiveCurrentVehicle() {
        vehicle.isArchived = true
        try? modelContext.save()
        if let next = allVehicles.first(where: { $0.id != vehicle.id }) {
            onSelectVehicle(next.id)
        }
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


