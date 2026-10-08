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

/// Bridges `View.onHingeChange(isEnabled:_:)` (iOS 27.1+) into a plain Bool
/// binding, so callers don't have to store the real
/// `DeviceHingeContext`/`DeviceHinge.Status` types - those aren't available
/// pre-27.1, and this app's deployment target is 26.2. A no-op on older
/// OSes: `isPartiallyOpen` just never flips from its `false` default, so
/// whatever the caller does with it (e.g. MainDashboardView's side panel,
/// SettingsView's split view) stays in its normal, non-book-mode position.
/// Not private to MainDashboardView: SettingsView needs the same signal for
/// its own book-mode layout.
struct HingeTracker: ViewModifier {
    @Binding var isPartiallyOpen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange(isEnabled: true) { _, new in
                withAnimation(.smooth(duration: 0.3)) {
                    isPartiallyOpen = new.hinge?.status == .partiallyOpen
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Main Dashboard
struct MainDashboardView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
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
    @State private var sheetDetent: PresentationDetent = .fraction(0.42)
    @State private var selectedLogTab: LogTabChoice = .fuel
    @StateObject private var locationManager = CurrentLocationManager()
    @State private var isMapReady = false
    @StateObject private var menuCommands = MenuCommandBus.shared
    @ObservedObject private var quickActionManager = QuickActionManager.shared
    @State private var layoutMode: DashboardLayout = .bottomSheet
    /// Whether Duo's hinge is half-open ("book" mode) rather than closed or
    /// fully flat - drives the side panel sliding toward the hinge instead of
    /// staying docked at the trailing edge. A plain Bool, not the real
    /// `DeviceHinge.Status` (iOS 27.1+, see `HingeTracker` below): storing
    /// that type here would make this whole view unavailable pre-27.1.
    @State private var hingeIsPartiallyOpen = false
    /// Settled height of the portrait card, as a fraction of the screen.
    @State private var cardHeightFraction: CGFloat = 0.34

    /// Every sheet/alert flag DashboardSheetContent's presentations depend on,
    /// owned here rather than there. On iPad the sheet content is rebuilt from
    /// scratch whenever a rotation crosses the side-panel/bottom-panel width
    /// threshold (see `layout(_:)` below), which used to reset this state and
    /// silently dismiss whatever was open. This view isn't rebuilt on that
    /// switch, only its overlay contents are, so state living here survives it.
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

    /// Width of the reserved vertical control column on Duo's *outer*
    /// display, or 0 everywhere else.
    ///
    /// Closed, Duo's outer display is wider and shorter than a normal
    /// iPhone, and the system moves the status bar, Dynamic Island, and (for
    /// standard nav/tab bars) app controls into a column on the trailing
    /// edge instead of across the top. That column is reserved *for*
    /// controls, not reserved *from* them - a system toolbar's close button
    /// lands centred inside it, not clear of it - so custom floating
    /// controls that play the same role should move into it too, matching
    /// where the system puts its own. Confirmed 84pt on-device via debug
    /// logging; a regular iPhone reports 0 in portrait.
    ///
    /// Regular iPhones can still report a modest leading/trailing inset in
    /// landscape (notch/Dynamic Island avoidance on whichever edge it
    /// rotates to), but that's well under 70pt - this threshold keeps
    /// ordinary landscape iPhones from being mistaken for Duo's much wider
    /// column.
    private func trailingClusterWidth(_ proxy: GeometryProxy) -> CGFloat {
        let trailing = proxy.safeAreaInsets.trailing
        return trailing > 70 ? trailing : 0
    }

    /// `trailingClusterWidth`, but also true when Duo's unfolded inner
    /// display has rotated into `.bottomSheet` (no real reserved column in
    /// that orientation - `trailingClusterWidth` alone reports 0 there) -
    /// requested directly: the 4 header icons should relocate into the same
    /// vertical column there too, matching the outer display, rather than
    /// sitting inline just because this particular rotation has no actual
    /// camera-cluster safe area to avoid.
    ///
    /// Gated on `horizontalSizeClass == .regular`, not the idiom check used
    /// elsewhere in this file - a real iPhone is always compact here, even
    /// landscape, so this can't mistake one for Duo the way an idiom-only
    /// check might if Apple ever ships a compact-but-.phone edge case.
    /// Falls back to 84 (Duo's own real reserved-column width, measured on
    /// the outer display) purely so the relocated column's own margin maths
    /// - tuned against that real value - produces the same proportions here.
    ///
    /// Also requires `proxy.size.width` past a floor - confirmed on-device
    /// that Split View still reports `.regular` for a Duo pane shared with
    /// another app (e.g. Settings docked beside it), which is nowhere near
    /// wide enough for a floating icon column to make sense and, worse,
    /// fed the same width into `relocatedColumnNeedsManualInset`'s 84pt
    /// manual content inset, squeezing an already-narrow pane further and
    /// losing the icons entirely. 600 sits well below a rotated *full*
    /// inner display's own width (which this case is actually meant for)
    /// and well above a half-and-half Split View pane's.
    private func sheetIconClusterWidth(_ proxy: GeometryProxy) -> CGFloat {
        let real = trailingClusterWidth(proxy)
        guard real == 0, horizontalSizeClass == .regular, proxy.size.width > 600 else { return real }
        return 84
    }

    /// True only when Fuel Log occupies the *leading* pane of a two-app
    /// Split View on Duo - requested directly: in that configuration, all
    /// 6 floating controls (the map's globe/locate, plus the dashboard's 4
    /// quick-action icons) should consolidate into one horizontal row
    /// hugging the true left edge, mirroring the single reserved-column
    /// convention used elsewhere on Duo - just mirrored to the opposite
    /// edge, and horizontal rather than vertical, since this isn't a real
    /// reserved hardware column to centre within.
    ///
    /// Narrow-width floor shared with `sheetIconClusterWidth`, for the same
    /// reason (a genuinely narrow Split View pane, not Duo's own full
    /// rotated display). `proxy.frame(in: .global).minX` near zero is what
    /// actually distinguishes the leading pane from the trailing one -
    /// Split View gives neither pane a `safeAreaInsets` signal to key off,
    /// but each pane's own frame in the window's global coordinate space
    /// still reflects which side of the screen it's docked to.
    private func isLeadingSplitViewPane(_ proxy: GeometryProxy) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, proxy.size.width <= 600 else { return false }
        // Duo's closed *outer* display is also narrow and flush with the
        // left edge, so it would otherwise match below. It's told apart by
        // its real reserved trailing column (`trailingClusterWidth` > 0),
        // which a Split View pane never has.
        guard trailingClusterWidth(proxy) == 0 else { return false }
        return proxy.frame(in: .global).minX < 10
    }

    /// Extra vertical clearance so the map controls sit below the column
    /// rather than beside it. `safeAreaInsets` only gives a flat edge width,
    /// not the column's actual height, so this is a calibrated estimate from
    /// the on-device screenshot (measured ~154pt tall) rather than a value
    /// read from any API - revisit if that changes.
    ///
    /// Lowered from 165 (the measured cluster height plus an 11pt buffer) -
    /// requested directly, the buttons should sit closer to the status bar
    /// than that buffer left them. Still some margin below the cluster
    /// rather than flush against it.
    private static let trailingClusterHeightEstimate: CGFloat = 130

    /// The map controls' own rendered diameter (title3 icon + 12pt padding),
    /// used to centre them inside the reserved column rather than clear of
    /// it. Matches the on-device measurement (~47pt).
    private static let mapControlButtonDiameter: CGFloat = 47

    /// A floating map control button (globe/locate) - Liquid Glass where
    /// available, falling back to the hand-drawn regularMaterial circle on
    /// earlier versions. `.glassEffect(_:in:)` applied directly to the
    /// label, explicitly shaped as a `Circle`, rather than
    /// `.buttonStyle(.glass)` - that style sizes its own capsule/circle
    /// backdrop to fit the label's own content, which on-device rendered as
    /// a visibly different-width oval per icon (each SF Symbol glyph has
    /// its own natural bounding box) instead of a uniform circle, and
    /// wrapping the label in an explicit `.frame` first didn't change that
    /// - the frame constrained the button's tappable area, not the glass
    /// shape drawn inside it. Sizing the label to `mapControlButtonDiameter`
    /// *before* the glassEffect is what actually forces a true circle.
    @ViewBuilder
    private func mapControlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage).font(.title3).foregroundColor(.primary)
                    .frame(width: Self.mapControlButtonDiameter, height: Self.mapControlButtonDiameter)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            Button(action: action) { Image(systemName: systemImage).font(.title3).foregroundColor(.primary).padding(12).background(.regularMaterial).clipShape(Circle()).shadow(radius: 2) }
                .frame(width: Self.mapControlButtonDiameter, height: Self.mapControlButtonDiameter)
                .hoverEffect(.highlight)
        }
    }

    /// How much further left the reserved column's true centre sits than
    /// treating it as flush against the trailing screen edge would suggest.
    /// Measured on-device from a raw (unscaled, 1pt-per-pixel) screenshot:
    /// the status bar cluster (camera/clock/wifi) centred at x≈417.55 out of
    /// a 466pt-wide screen, while naively centring a button in an 84pt
    /// column flush against x=466 puts it at x≈424 - about 6pt too far
    /// right. Shared with DashboardSheetContent's relocatedIconRow, which
    /// has the same constant under the same name for the same reason.
    private static let reservedColumnRightMargin: CGFloat = 6

    /// The floating globe/locate buttons over the map, and the full-screen
    /// map's own presentation. Split out of `body` as its own function -
    /// nested inline, this pushed the type checker over its time limit.
    ///
    /// The plus/map/share/gear icons (see DashboardSheetContent.relocatedIconRow)
    /// are NOT drawn here even though they visually join this same column:
    /// a sheet's presentation always renders above its presenter, and
    /// confirmed on-device that presentationBackgroundInteraction doesn't
    /// reliably forward taps to specific buttons underneath it. They have
    /// to live inside the sheet itself to stay tappable.
    ///
    /// A NavigationStack + .toolbar{} version of this was tried instead,
    /// hoping the system would place the icons automatically the way
    /// Settings' close button does - it did relocate them vertically, but
    /// tied to wherever *this view's own* trailing edge was, not the true
    /// hardware column (confirmed on-device: they landed inside the pill's
    /// own bounds, not lined up with the status icons). Reverted - untying
    /// their position from the pill's width needs the manual
    /// ignoresSafeArea approach below.
    @ViewBuilder
    private func mapControlsOverlay(_ proxy: GeometryProxy) -> some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    if colorScheme != .dark {
                        mapControlButton(systemImage: useSatellite ? "map.fill" : "globe.americas.fill") { useSatellite.toggle() }
                    }
                    mapControlButton(systemImage: "location.fill") {
                        if let loc = locationManager.location { withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else {
                            locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) }; locationManager.onLocationUpdate = nil }
                            locationManager.requestLocation()
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
                // Sits below Duo's outer-display control column rather
                // than beside it: closed, the status bar/Dynamic Island
                // stack vertically down the trailing edge instead of
                // sitting centred across the top.
                .padding(.top, trailingClusterWidth(proxy) > 0 ? Self.trailingClusterHeightEstimate : 16)
                // On a normal iPhone/iPad this just clears the true
                // trailing edge (or the side panel). On Duo's outer
                // display it instead centres these inside the reserved
                // column, matching where the system places its own
                // toolbar buttons there (see trailingClusterWidth) -
                // which needs the HStack below to actually reach that
                // column, hence ignoresSafeArea on the trailing edge.
                //
                // reservedColumnRightMargin corrects for the reserved
                // column not actually being flush against the true
                // trailing edge - confirmed on-device (measuring a raw,
                // unscaled screenshot in points) that the status bar
                // cluster (camera/clock/wifi) sits centred ~6pt further
                // left than centring against the bare trailing edge
                // assumes, i.e. there's a small margin beyond the
                // column's own right edge before the true screen edge.
                .padding(.trailing, trailingClusterWidth(proxy) > 0
                    ? max(0, (trailingClusterWidth(proxy) - Self.mapControlButtonDiameter) / 2 + Self.reservedColumnRightMargin)
                    : 16 + (layout(proxy) == .sidePanel ? Self.panelWidth : 0))
                .opacity(isMapReady ? 1 : 0)
            }
            Spacer()
        }
        .ignoresSafeArea(.container, edges: .trailing)
        .fullScreenCover(isPresented: $showFullScreenMap) { NavigationStack { VehicleMapView(vehicle: vehicle, useSatellite: $useSatellite, selectedTab: selectedLogTab, initialSelection: nil) } }
    }

    /// The permanently-presented bottom sheet used on compact width (a
    /// regular iPhone, or Duo's outer display). Split out of `body` as its
    /// own function for the same reason as `mapControlsOverlay` - nested
    /// inline, this pushed the type checker over its time limit.
    ///
    /// Reverted to the plain full-width pill from before any Duo-specific
    /// narrowing: every attempt to cap this sheet's width to clear the
    /// reserved column (a fixed pixel value, then 80% of the full width)
    /// surfaced a translucent "haze" artifact in the gap that survived four
    /// distinct fix attempts (an unfilled canvas gap, an explicit
    /// Color.clear sibling, dropping panelBackground's glassEffect for a
    /// plain fill, and nullifying the sheet's default background outright
    /// via presentationBackground(.clear) combined with an ordinary
    /// .background() on the content) - each ruled out the specific
    /// mechanism it targeted without ever finding the real cause. Not
    /// worth further cycles right now; the icons that need to clear the
    /// column live in relocatedIconRow instead, positioned independently
    /// of whatever width this pill has.

    @ViewBuilder
    private func bottomSheetContent(_ proxy: GeometryProxy) -> some View {
        DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: $sheetDetent, clusterWidth: sheetIconClusterWidth(proxy), screenHeight: fullHeight(proxy), relocatedColumnNeedsManualInset: trailingClusterWidth(proxy) == 0, hidesInlineIcons: isLeadingSplitViewPane(proxy), leadingPaneIconColumn: isLeadingSplitViewPane(proxy), showingAddFillUp: $showingAddFillUp, fillUpEntryMode: $fillUpEntryMode, showingAddService: $showingAddService, showingTrips: $showingTrips, showingSettings: $showingSettings, showingArchivedVehicles: $showingArchivedVehicles, showingAddVehicle: $showingAddVehicle, showingDeleteConfirmation: $showingDeleteConfirmation, showingCharts: $showingCharts, showingMonthlyReport: $showingMonthlyReport, monthlyReportMonth: $monthlyReportMonth, eventToEdit: $eventToEdit, vehicleToEdit: $vehicleToEdit)
            .presentationDetents([.fraction(0.42), .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible).presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42))).interactiveDismissDisabled()
            .presentationBackground { panelBackground(in: Rectangle()) }
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
    private static let smallestSheetFraction: CGFloat = 0.42
    /// The tallest detent the map still pans for. Beyond this so little map is
    /// left that panning is skipped, so it doesn't constrain the zoom.
    private static let tallestPannedSheetFraction: CGFloat = 0.65

    /// How much of the screen the bottom sheet currently covers. `PresentationDetent`
    /// doesn't expose its fraction, so map the known detents back to their values.
    /// Only two detents are offered now (small/large) - the middle one was
    /// removed at the user's request.
    private var sheetFraction: CGFloat {
        sheetDetent == .large ? 0.92 : Self.smallestSheetFraction
    }

    /// Width the side panel needs before it earns its place: 420pt of panel plus
    /// enough map beside it to still be worth looking at. Sits between iPad
    /// portrait (1024pt, card) and iPad mini landscape (1133pt, panel).
    private static let sidePanelMinimumWidth: CGFloat = 1080
    /// Same idea, but for Duo's unfolded inner display specifically -
    /// comfortably under `sidePanelMinimumWidth` (tuned for iPad's much
    /// larger range of window sizes), so a straight reuse of that threshold
    /// left Duo's inner display on the card instead of the panel the user
    /// actually wanted there. Not just a lower `sidePanelMinimumWidth` for
    /// everyone - that would also pull in any iPad window between this and
    /// 1080pt wide (e.g. certain Split View widths), a behaviour change for
    /// iPad nobody asked for.
    ///
    /// 840, not a number closer to 951 (the window's full/raw size reported
    /// by the device destination): confirmed via a temporary on-screen
    /// debug overlay (device-interaction screenshots of this exact state
    /// kept coming back solid black, so a visible overlay the user could
    /// screenshot normally was the only reliable way to check) that
    /// `proxy.size.width` - the value `layout(_:)` actually compares against
    /// - measures 867pt here, not 951pt. The ~84pt gap is the same reserved
    /// trailing safe-area column seen on the *outer* display
    /// (`trailingClusterWidth`), apparently still carved out of `proxy.size`
    /// on the unfolded inner display too. An earlier version of this
    /// constant (900) was calibrated against the wrong (raw window) number
    /// and so never actually cleared 867, silently keeping the old
    /// `.bottomPanel` behaviour despite looking correct on paper.
    private static let duoSidePanelMinimumWidth: CGFloat = 840
    /// Extra shrink required to give the side panel up once it's shown, so a
    /// window parked on the threshold doesn't flicker between layouts.
    private static let layoutSwitchHysteresis: CGFloat = 60
    fileprivate static let layoutChangeAnimation: Animation = .smooth(duration: 0.3)

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
    /// An unfolded Duo reports a regular horizontal size class while its idiom
    /// stays `.phone`, so it's let through here too - it lands on the same
    /// panel-vs-card choice below as iPad, just measured against
    /// `duoSidePanelMinimumWidth` instead of iPad's own threshold (Duo's
    /// inner display, 951pt wide, clears that lower bar and lands on the
    /// side panel - the user explicitly wants Duo's inner display to read as
    /// the full docked panel, not the card iPad itself falls back to below
    /// its own, much higher, threshold).
    ///
    /// The panel-vs-card choice is width, not the aspect ratio it once compared.
    /// Aspect flipped a near-square window on a tiny drag, and near-square is
    /// exactly where windows get parked.
    private func layout(_ proxy: GeometryProxy) -> DashboardLayout {
        guard UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular else { return .bottomSheet }
        // Whenever Duo doesn't have room for the side panel, it should fall
        // back to looking like its own outer/closed display (the sheet),
        // never iPad's floating card - requested directly, after a fully
        // unfolded Duo rotated into a narrow/portrait pose landed on the
        // card by sharing iPad's own fallback below. `.bottomPanel` is only
        // ever right for an actual iPad; Duo reaches this function at all
        // because it shares iPad's regular-size-class guard above.
        let fallback: DashboardLayout = UIDevice.current.userInterfaceIdiom == .phone ? .bottomSheet : .bottomPanel
        // The side panel only ever makes sense with width to spare beside the
        // map, so a portrait-shaped window is always the fallback -
        // regardless of hysteresis. Without this coarse guard, a 13" iPad's
        // portrait width (1032pt) sits *above* the hysteresis-lowered
        // threshold (1020pt), so rotating landscape -> portrait right after
        // the side panel had shown left portrait stuck showing the side
        // panel too. This is a guard at the extreme (width <= height), not
        // the continuous ratio comparison that used to flicker on a
        // near-square drag - real portrait/landscape aspects aren't
        // anywhere near that boundary.
        guard proxy.size.width > proxy.size.height else { return fallback }
        let minimumSidePanelWidth = UIDevice.current.userInterfaceIdiom == .pad
            ? Self.sidePanelMinimumWidth
            : Self.duoSidePanelMinimumWidth
        let threshold = layoutMode == .sidePanel
            ? minimumSidePanelWidth - Self.layoutSwitchHysteresis
            : minimumSidePanelWidth
        return proxy.size.width >= threshold ? .sidePanel : fallback
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
    /// Same idea, but narrower for Duo's unfolded inner display specifically -
    /// at the iPad width, the panel's own leading edge landed ~28pt past the
    /// physical hinge, into the left half of the unfolded display (confirmed
    /// on-device from a user screenshot). iPad has no hinge to worry about,
    /// so this doesn't touch `panelWidth` itself - only Duo's own call sites
    /// (via `panelWidth(_:)` below) pick this one instead.
    ///
    /// 340, not the 370 that first cleared the hinge: confirmed on-device
    /// that 370 left only ~21pt of clearance past the hinge - technically
    /// clear, but still read as "close to the hinge" in a screenshot. 340
    /// roughly doubles that margin.
    ///
    /// 346, not 340: closes the gap to the icon column by a few points
    /// (the icons themselves can't move - they're pinned to line up with
    /// the true status-bar column above them) while staying well clear of
    /// the hinge margin above.
    private static let duoPanelWidth: CGFloat = 346

    /// Which of the two width constants above applies, based on idiom - see
    /// `duoPanelWidth`'s own comment for why Duo needs a narrower one.
    private func panelWidth(_ proxy: GeometryProxy) -> CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? Self.panelWidth : Self.duoPanelWidth
    }

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
                              trailingPadding: layout(proxy) == .sidePanel ? panelWidth(proxy) : 0,
                              onCameraChange: { region in
                    adoptUserZoom(region.span)
                })
                    .transition(.opacity)
                    .onChange(of: selectedEventID) { _, newID in
                        if let id = newID, let ev = displayedEvents.first(where: { $0.id == id }) { mapEventToView = ev; selectedEventID = nil }
                    }
                    .sheet(item: $mapEventToView) { ev in RecordReadOnlyDetailView(event: ev) }
            }
            
            // Side panel gets its own consolidated copy of these controls
            // instead (see sidePanelIconColumn, added as a *later* .overlay
            // below, on top of sidePanel's own - nesting it in here would
            // draw it underneath the panel instead, since .overlay always
            // draws on top of everything already inside the view it's
            // chained onto, regardless of sibling order within that view).
            // Leading Split View pane gets its own consolidated row
            // instead (see leadingIconRow, added as a later .overlay
            // below) - same reasoning as the side panel case just above.
            if layout(proxy) != .sidePanel && !isLeadingSplitViewPane(proxy) {
                mapControlsOverlay(proxy)
            }
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
            if layout(proxy) == .sidePanel { sidePanel(proxy) }
        }
        // A separate, later .overlay than sidePanel's own above - each
        // .overlay draws on top of everything before it (including a prior
        // .overlay), which is what actually puts these icons on top of the
        // panel instead of underneath it. Confirmed on-device: nesting this
        // inside the same ZStack sidePanel's content lives in, earlier,
        // left it drawn first and so painted over by the panel.
        .overlay(alignment: .trailing) {
            if layout(proxy) == .sidePanel { sidePanelIconColumn(proxy) }
        }
        .overlay(alignment: .leading) {
            if isLeadingSplitViewPane(proxy) { leadingIconRow(proxy) }
        }
        .overlay(alignment: .bottomLeading) {
            if layout(proxy) == .bottomPanel { bottomPanel(proxy) }
        }
        .modifier(HingeTracker(isPartiallyOpen: $hingeIsPartiallyOpen))
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
            bottomSheetContent(proxy)
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
        // Home Screen quick actions / Siri, once a vehicle exists. ContentView
        // owns the equivalent handling for the empty-garage case; this view is
        // only ever on screen when there's a vehicle, and its own sheets are
        // what actually need to present, so it has to react directly rather
        // than relying on a handler declared above it in the hierarchy.
        .onAppear { handleQuickAction(quickActionManager.action) }
        .onChange(of: quickActionManager.action) { _, action in handleQuickAction(action) }
        }
    }

    private func handleQuickAction(_ action: QuickActionManager.QuickAction?) {
        guard let action else { return }
        let delay = quickActionManager.actionIsImmediate ? 0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch action {
            case .addFuel: showingAddFillUp = true
            case .addService: showingAddService = true
            case .addVehicle: showingAddVehicle = true
            }
            quickActionManager.action = nil
            quickActionManager.actionIsImmediate = false
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
    ///
    /// Extended all the way to the true trailing edge (past the reserved
    /// control column Duo's unfolded inner display still carves out of
    /// `proxy.size`, same as its outer display does) rather than stopping at
    /// the safe area boundary the way this panel originally did for iPad -
    /// on-device, that left a visible gap of bare map between the panel's
    /// own trailing edge and the true screen edge, with the map's
    /// globe/locate buttons floating alone in it. Requested directly: the
    /// panel should fill that gap, and the controls that used to float in
    /// it (globe, locate) should live inside the panel instead, alongside
    /// the header's own quick-action icons - all six consolidated into one
    /// vertical column in this extended strip, rather than two separate
    /// clusters (one inline in the header, one floating over the map).
    ///
    /// The panel's own content stays at its original `panelWidth` - only the
    /// *background* extends into the reserved column, leading-aligned so
    /// the extra width is added on the trailing side only (a background
    /// wider than its view centres by default, which would've pushed half
    /// the extra width onto the *leading* side instead, misaligning it with
    /// the content sitting in front of it).
    ///
    /// The consolidated icon column itself (globe/locate plus the header's
    /// quick-action icons) is NOT nested inside this view - see
    /// `sidePanelIconColumn(_:)`, rendered as its own sibling at the body
    /// level instead, for why nesting it here doesn't reliably reach the
    /// true trailing edge the same way.
    /// The panel's leading edge, in `proxy.size`-space: flush against the
    /// physical hinge in "book" mode (Duo's hinge half-open rather than
    /// closed or fully flat - see `HingeTracker`), or its normal
    /// trailing-docked position otherwise. Centring the panel *on* the hinge
    /// was tried first and confirmed on-device that it straddled both
    /// displays, which read as the panel still being pinned across the seam
    /// rather than having moved - it needs to stay entirely on the display
    /// it already lives on, just sliding over to meet the hinge instead of
    /// the true trailing edge.
    ///
    /// The hinge sits at the midpoint of the *raw* width, not `proxy.size`'s
    /// (that excludes the reserved trailing column - see
    /// `trailingClusterWidth`'s own comment), so it's added back in just for
    /// this calculation.
    private func panelLeadingEdge(_ proxy: GeometryProxy) -> CGFloat {
        guard hingeIsPartiallyOpen else { return proxy.size.width - panelWidth(proxy) }
        return (proxy.size.width + trailingClusterWidth(proxy)) / 2
    }

    /// Breathing room the data-entry sheet keeps clear of `panelLeadingEdge`,
    /// so its right edge doesn't land flush against the panel/hinge boundary.
    /// Landing exactly on it read, on-device, as the sheet touching/crossing
    /// the fold rather than sitting safely on its own half - requested
    /// directly ("the left pill overlaps the hinge, move it a lil back left").
    private static let duoSheetHingeMargin: CGFloat = 16

    /// The content's displayed width: normally `panelWidth(_:)`, but wider
    /// in "book" mode to actually use the extra room gained by the leading
    /// edge moving to the hinge, rather than leaving it as empty glass
    /// between the content and the icon column. Trailing-aligned like the
    /// content itself, so its right edge always lands at `proxy.size.width`
    /// - identical to the docked case - regardless of mode; only the
    /// leading edge differs, which is what makes this naturally land at
    /// `panelLeadingEdge(_:)` without a separate offset.
    private func panelContentWidth(_ proxy: GeometryProxy) -> CGFloat {
        proxy.size.width - panelLeadingEdge(proxy)
    }

    private func sidePanel(_ proxy: GeometryProxy) -> some View {
        DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: .constant(.large), hidesInlineIcons: true, isSidePanelLayout: true, duoLeadingSheetWidth: max(panelLeadingEdge(proxy) - Self.duoSheetHingeMargin, 0), showingAddFillUp: $showingAddFillUp, fillUpEntryMode: $fillUpEntryMode, showingAddService: $showingAddService, showingTrips: $showingTrips, showingSettings: $showingSettings, showingArchivedVehicles: $showingArchivedVehicles, showingAddVehicle: $showingAddVehicle, showingDeleteConfirmation: $showingDeleteConfirmation, showingCharts: $showingCharts, showingMonthlyReport: $showingMonthlyReport, monthlyReportMonth: $monthlyReportMonth, eventToEdit: $eventToEdit, vehicleToEdit: $vehicleToEdit)
            .frame(width: panelContentWidth(proxy))
            .frame(maxHeight: .infinity)
            .background(alignment: .leading) {
                // Only the glass runs to the screen edges, not the content -
                // letting the whole panel ignore the safe area would slide
                // the header text under the status bar, but leaving the
                // background inside it stranded a visible strip of map
                // above, below, and trailing, so the panel looked clipped.
                //
                // One ignoresSafeArea call for all three edges, not two
                // separate calls (one for .vertical, one for .container
                // .trailing, as an earlier version had) - confirmed
                // on-device that chaining two separate calls left a gap
                // between the panel's top and the true top of the screen,
                // as if the vertical one hadn't actually applied; combining
                // every edge into one call is what actually reaches all of
                // them, not just the last one called.
                //
                // A two-layer (glass + separate plain trailing strip)
                // version was tried here to avoid a dark-mode glass ghost
                // artifact at the leading corner - reverted after it threw
                // off the panel's own position/sizing on-device. Back to
                // the single glass layer; the ghost is a known, separately
                // tracked issue, not fixed by that attempt.
                //
                // Clipped to the glass's own shape: in dark mode the glass
                // (over its black 50% fill) paints a soft dark halo just
                // *outside* its leading edge and corners, which read as a
                // shadow behind the panel's edge against the map -
                // requested to be fixed. Clipping cuts off anything drawn
                // beyond the shape and leaves the glass's own rim intact.
                let panelShape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28, style: .continuous)
                panelBackground(in: panelShape, frosted: true)
                    .clipShape(panelShape)
                    .frame(width: proxy.size.width + trailingClusterWidth(proxy) - panelLeadingEdge(proxy))
                    .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
            }
            .transition(.move(edge: .trailing))
    }

    /// The six controls that used to be two separate clusters - the map's
    /// own floating globe/locate buttons, and the side panel header's
    /// quick-action icons - consolidated into one vertical column, in the
    /// same reserved trailing column `mapControlsOverlay` already centres
    /// its own buttons within on Duo's *outer* display. Requested directly:
    /// since the panel now extends into that column (see `sidePanel(_:)`),
    /// a separately-floated copy of the map buttons would render underneath
    /// it, unreachable - and the header's own icons need to come out of the
    /// header for the same reason `hidesInlineIcons` exists.
    ///
    /// A top-level ZStack sibling (alongside `mapControlsOverlay`), not
    /// nested inside `sidePanel(_:)`'s own returned view, for the same
    /// reason `relocatedIconRow` on Duo's outer display isn't nested inside
    /// `DashboardSheetContent`'s own content VStack either: nesting it
    /// inside a view that's itself constrained to `panelWidth` would only
    /// ever get proposed that same constrained width to lay out in, leaving
    /// `ignoresSafeArea` nothing beyond it to reach past. As a sibling of
    /// the full-screen ZStack in `body` instead, it's proposed the whole
    /// screen's width, which is what lets it reach the true trailing edge.
    ///
    /// Builds its own `DashboardSheetContent` value purely to read
    /// `quickIconColumn` off it - a second *value* (cheap; a plain
    /// description of a view, not a second live instance of anything), not
    /// a second rendering of the panel itself.
    ///
    /// Two separate groups, not one combined column - matching Duo's
    /// *outer* display, where the map's globe/locate buttons stay pinned
    /// near the status-bar cluster while the header's quick-action icons
    /// sit at their own fixed position further down. An earlier version
    /// stacked all six in one column near the top; confirmed on-device that
    /// put the first icon (globe) directly behind the status bar's own
    /// time/wifi content - this view ignoresSafeArea to reach the trailing
    /// edge, which (with no explicit top inset of its own) also let it
    /// reach above the top safe area inset the status bar occupies.
    /// `topGroupClearance` pushes the top group below that; the bottom
    /// group uses a `Spacer()` to anchor near the bottom instead, with its
    /// own small margin.
    private func sidePanelIconColumn(_ proxy: GeometryProxy) -> some View {
        let content = DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: .constant(.large), hidesInlineIcons: true, showingAddFillUp: $showingAddFillUp, fillUpEntryMode: $fillUpEntryMode, showingAddService: $showingAddService, showingTrips: $showingTrips, showingSettings: $showingSettings, showingArchivedVehicles: $showingArchivedVehicles, showingAddVehicle: $showingAddVehicle, showingDeleteConfirmation: $showingDeleteConfirmation, showingCharts: $showingCharts, showingMonthlyReport: $showingMonthlyReport, monthlyReportMonth: $monthlyReportMonth, eventToEdit: $eventToEdit, vehicleToEdit: $vehicleToEdit)
        // Centred within the reserved column, plus the same
        // reservedColumnRightMargin correction as the outer display's
        // version of this math - a left-hugging formula was tried here to
        // close up the gap to the panel's own content, but confirmed
        // on-device that it put the globe/locate buttons ~13pt further
        // left than the true status-bar column above them (visibly
        // misaligned, since this reserved column is this display's actual
        // status-bar strip, not a free-floating hardware cluster like the
        // outer display's). Centring is what lines them up.
        let trailingPadding = max(0, (trailingClusterWidth(proxy) - Self.mapControlButtonDiameter) / 2 + Self.reservedColumnRightMargin)
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    if colorScheme != .dark {
                        mapControlButton(systemImage: useSatellite ? "map.fill" : "globe.americas.fill") { useSatellite.toggle() }
                    }
                    mapControlButton(systemImage: "location.fill") {
                        if let loc = locationManager.location { withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else {
                            locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) }; locationManager.onLocationUpdate = nil }
                            locationManager.requestLocation()
                        }
                    }
                }
                .padding(.top, Self.sidePanelTopGroupClearance)
                .padding(.trailing, trailingPadding)
            }
            Spacer()
            HStack {
                Spacer()
                content.quickIconColumn
                    .padding(.bottom, 32)
                    .padding(.trailing, trailingPadding)
            }
        }
        .ignoresSafeArea(.container, edges: .trailing)
    }

    /// Duo's leading-pane Split View: just the map's globe/locate buttons,
    /// in a row hugging the true left edge - see `isLeadingSplitViewPane(_:)`
    /// for when this applies. The 4 quick-action icons are *not* here: they
    /// live inside the pill itself (`DashboardSheetContent.leadingPaneIconColumn`),
    /// requested directly.
    private func leadingIconRow(_ proxy: GeometryProxy) -> some View {
        VStack {
            // Stacked, globe above location, against the left edge -
            // requested directly. In dark mode the globe is hidden and
            // location sits alone at the top.
            HStack {
                VStack(spacing: 12) {
                    if colorScheme != .dark {
                        mapControlButton(systemImage: useSatellite ? "map.fill" : "globe.americas.fill") { useSatellite.toggle() }
                    }
                    mapControlButton(systemImage: "location.fill") {
                        if let loc = locationManager.location { withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) } } else {
                            locationManager.onLocationUpdate = { loc in withAnimation(.easeInOut(duration: 0.5)) { mapPosition = .region(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)) }; locationManager.onLocationUpdate = nil }
                            locationManager.requestLocation()
                        }
                    }
                }
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.top, 16)
            Spacer()
        }
        .ignoresSafeArea(.container, edges: .leading)
    }

    /// How far below the true top edge the globe/locate buttons need to sit
    /// to clear Duo's unfolded inner display's own (normal, horizontal)
    /// status bar - calibrated from a user screenshot showing the globe
    /// button's icon rendering directly behind the status bar's time/wifi
    /// content at the previous value (24pt, nowhere near enough). Unlike
    /// the outer display's reserved column, this is an ordinary top status
    /// bar, not a special hardware cluster - the number is just taller than
    /// a typical safe-area top inset because Duo's unfolded status bar
    /// itself is taller than a normal iPhone's.
    private static let sidePanelTopGroupClearance: CGFloat = 130

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
            // Identical code for every call site (the inner side panel and
            // the outer display's bottomPanel both land here) - requested
            // directly, after three attempts at a dark-mode-specific
            // adjustment (a flat fill to avoid a glass edge-highlight
            // ghost; that same fill at a higher opacity; a Material
            // instead of a flat fill) each made the inner panel look
            // different from the outer one instead of matching it. Back to
            // exactly what this was before any of those attempts.
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
        //
        // The right edge is measured against a reserved trailing control
        // column when there is one (see trailingClusterWidth), not the true
        // screen edge - otherwise the card reads as running underneath it.
        let rightBoundary = proxy.size.width - max(Self.bottomCardMargin, trailingClusterWidth(proxy))
        let available = max(rightBoundary - Self.bottomCardMargin, 1)
        let preferred = min(max(proxy.size.width * Self.bottomCardWidthFraction, Self.bottomCardMinWidth), Self.bottomCardMaxWidth)
        let width = min(preferred, available)
        return VStack(spacing: 0) {
            bottomCardPullBar(full: full)
            DashboardSheetContent(colorScheme: _colorScheme, vehicle: vehicle, allVehicles: allVehicles, events: timelineEvents, onSelectVehicle: onSelectVehicle, newReportMonth: newReportMonth, onAcknowledgeReport: onAcknowledgeReport, selectedLogTab: $selectedLogTab, sheetDetent: .constant(.large), showingAddFillUp: $showingAddFillUp, fillUpEntryMode: $fillUpEntryMode, showingAddService: $showingAddService, showingTrips: $showingTrips, showingSettings: $showingSettings, showingArchivedVehicles: $showingArchivedVehicles, showingAddVehicle: $showingAddVehicle, showingDeleteConfirmation: $showingDeleteConfirmation, showingCharts: $showingCharts, showingMonthlyReport: $showingMonthlyReport, monthlyReportMonth: $monthlyReportMonth, eventToEdit: $eventToEdit, vehicleToEdit: $vehicleToEdit)
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
    /// Width of Duo's outer-display reserved control column, or 0 elsewhere
    /// - see MainDashboardView.trailingClusterWidth(_:). Threaded in rather
    /// than measured locally, since the parent already has to compute it for
    /// the map controls and the card's own width.
    var clusterWidth: CGFloat = 0
    /// Full screen height (including safe areas - see
    /// MainDashboardView.fullHeight(_:)), threaded in the same way as
    /// `clusterWidth`. Only meaningful alongside `clusterWidth > 0`: it's
    /// what `relocatedIconTargetAbsoluteY` derives the resting small pill's
    /// geometry from, so the relocated icon column centres correctly
    /// whatever size screen it's drawn on, rather than the fixed pixel
    /// value this was hardcoded to before - that was calibrated by hand for
    /// Duo's own outer display specifically, and silently put the column
    /// mostly off-screen the moment `clusterWidth` started being forced on
    /// for a differently-sized screen (Duo's unfolded inner display,
    /// rotated into `.bottomSheet` - see `MainDashboardView.sheetIconClusterWidth(_:)`).
    var screenHeight: CGFloat = 0
    /// True only when `clusterWidth` is a synthetic stand-in rather than a
    /// real system-reported safe area (Duo's unfolded inner display,
    /// rotated into `.bottomSheet` - see
    /// `MainDashboardView.sheetIconClusterWidth(_:)`). On Duo's outer
    /// display, a *real* reserved column already narrows this whole view's
    /// available width before its body even runs, which is why no row here
    /// adds its own extra trailing padding for the relocated icon column
    /// (confirmed on-device: the existing 24pt horizontal padding already
    /// clears it with room to spare). A synthetic `clusterWidth` has no
    /// such real safe area doing that narrowing, so without this, content
    /// stretches the full screen width and collides with the floating icon
    /// column instead of clearing it - requested directly ("move the data
    /// over a little so that the icons aren't cut off").
    var relocatedColumnNeedsManualInset: Bool = false
    /// True for the side panel only: MainDashboardView.sidePanel renders its
    /// own copy of `quickIconColumn` (pulled directly off a second instance
    /// of this view, alongside the map's globe/locate buttons) in the
    /// panel's extended trailing strip, so this view's own header shouldn't
    /// also render them inline - they'd otherwise show up twice.
    var hidesInlineIcons: Bool = false
    /// True only for Fuel Log in the leading pane of a Duo Split View (see
    /// `MainDashboardView.isLeadingSplitViewPane(_:)`): the 4 quick-action
    /// icons stack vertically down the pill's own leading edge, centred
    /// vertically, instead of floating over the map or sitting in the
    /// header. Requested directly. Pair with `hidesInlineIcons`.
    var leadingPaneIconColumn: Bool = false
    /// True for the side panel only (same call sites as `hidesInlineIcons`
    /// above) - forwarded to `SettingsView(forcesRegularLayout:)`. A sheet
    /// presented from a `.phone`-idiom device (Duo included, even unfolded)
    /// always gives its content a compact `horizontalSizeClass` internally,
    /// regardless of this view's own environment or the sheet's actual
    /// width - confirmed on-device: Settings rendered its single-column
    /// phone layout here despite the side panel itself being `.regular`
    /// everywhere else. Real iPad needs no help, since its sheets do get a
    /// usable size class from their actual presented width.
    var isSidePanelLayout: Bool = false
    /// `nil` everywhere except the Duo side panel, where it's the exact
    /// width available on the leading side before the panel's own leading
    /// edge (`MainDashboardView.panelLeadingEdge(_:)`) - forwarded to
    /// `roomySheetOnPad(duoLeadingWidth:)` on the data-entry sheets so they
    /// dock to the leading half of the screen without crossing into the
    /// panel (or, in book mode, the hinge it's pinned against).
    var duoLeadingSheetWidth: CGFloat? = nil

    /// Owned by MainDashboardView, not here: this view is rebuilt from scratch
    /// whenever an iPad rotation crosses the side-panel/bottom-panel width
    /// threshold, and local @State here would reset (dismissing whatever was
    /// open) exactly when that happened.
    @Binding var showingAddFillUp: Bool
    @Binding var fillUpEntryMode: FillUpEntryMode
    @Binding var showingAddService: Bool
    @Binding var showingTrips: Bool
    @Binding var showingSettings: Bool
    @Binding var showingArchivedVehicles: Bool
    @Binding var showingAddVehicle: Bool
    @Binding var showingDeleteConfirmation: Bool
    @Binding var showingCharts: Bool
    @Binding var showingMonthlyReport: Bool
    @Binding var monthlyReportMonth: Date
    @Binding var eventToEdit: VehicleEvent?
    @Binding var vehicleToEdit: Vehicle?
    @State private var vehicleShareItem: VehicleShareItem?

    @State private var searchText: String = ""
    @StateObject private var sheetMenuCommands = MenuCommandBus.shared
    /// Measured, not estimated, once the sheet is first seen resting at its
    /// small detent - see `relocatedIconTargetAbsoluteY`'s own doc comment
    /// for why a measurement beats a formula here.
    @State private var measuredRestingIconTargetY: CGFloat? = nil

    var body: some View {
        // GeometryReader here (rather than threading a detent-based offset
        // in from MainDashboardView, as an earlier version did) is what
        // makes relocatedIconRow track the sheet's *actual* real-time
        // height during an interactive drag, not just its value at the two
        // settled detents. A detent-based offset is only correct once the
        // drag commits to .small or .large - mid-drag, this view's own
        // frame already resizes continuously (confirmed on-device via
        // screen recording), but the old offset stayed pinned to whichever
        // detent was last committed, so the icon column either drifted the
        // wrong way through most of the drag or sat still while everything
        // else moved, then snapped to the correct fixed position the
        // instant the detent flipped - a visible jump/bounce. Reading this
        // view's own live frame instead means the icon column is always
        // computed from where the sheet *actually* is this frame, so it
        // tracks smoothly with no separate detent-aware case needed.
        GeometryReader { geo in
        // relocatedIconRow is a sibling of the VStack below, not nested
        // inside it via .overlay() on that view - an overlay's content is
        // proposed the base view's own resolved size, which is exactly what
        // this row needs to reach past to get into the reserved column. As
        // a ZStack sibling instead, it's proposed this whole body's width,
        // which is never explicitly capped, so ignoresSafeArea inside it
        // has actual room to work with.
        ZStack(alignment: .topTrailing) {
        HStack(spacing: 0) {
        if leadingPaneIconColumn {
            // Same fixed absolute screen position at every detent -
            // requested directly (no moving, no animation between small and
            // large). Same technique as `relocatedIconRow`: top-aligned,
            // then offset by (target - this view's live top edge), so it
            // stays put as the pill grows. The target is the column centred
            // in the resting small pill.
            VStack(spacing: 0) {
                quickIconColumn
                    .offset(y: relocatedIconTargetAbsoluteY - geo.frame(in: .global).minY)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
        }
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                // No extra trailing inset needed for relocatedIconRow here,
                // on any row - this content's own `.padding(.horizontal, 24)`
                // already lands its right edge a comfortable ~14pt clear of
                // the icon column on its own (confirmed on-device), since
                // the sheet's content canvas isn't the bare screen width to
                // begin with (see sheetEdgeInset below). Two earlier
                // versions added one anyway: first to the *entire* scrolling
                // content (narrowing rows nowhere near the icon column, for
                // no reason - a wide empty strip down the whole right side
                // of the sheet), then narrowed to just the rows within the
                // icon column's vertical extent (the stats grid, quick
                // action buttons, and maintenance banner) - which turned out
                // to be redundant with the clearance those rows already
                // had, just adding unnecessary extra empty space above them
                // instead. Before that, an even earlier version reserved
                // *vertical* space above this ScrollView sized to clear the
                // icon column's full height, which was worse still - see
                // memory for the full history if this needs revisiting
                // again. The icon column simply floats over the corner of
                // whatever's there, the same way the map's own floating
                // buttons already do over the map, and needs nothing from
                // this content at all.
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
                            .hoverEffect(.highlight)
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
        // See `relocatedColumnNeedsManualInset`'s own doc comment: the real
        // outer-display case needs nothing here because a real safe area
        // already narrows this entire view's available width before its
        // body even runs. This mimics that same whole-view narrowing by
        // hand, for the one case where there's no real safe area doing it -
        // applied to this whole VStack rather than any individual row, to
        // match that real behaviour as closely as possible (every row,
        // including the scrolling log list, ends up equally narrower).
        .padding(.trailing, relocatedColumnNeedsManualInset ? clusterWidth : 0)
        }

        relocatedIconRow(sheetTopY: geo.frame(in: .global).minY)
        }
        // Captures the resting/small pill's *real* top and height the
        // moment the sheet is actually seen there, rather than estimating
        // them from `smallestSheetFraction * screenHeight` - see
        // `relocatedIconTargetAbsoluteY`'s own doc comment for why the
        // estimate isn't reliable enough on its own.
        .onGeometryChange(for: CGFloat.self, of: { proxy in
            proxy.frame(in: .global).minY + (proxy.size.height - Self.relocatedIconColumnHeight) / 2 + Self.measuredFrameCorrection
        }, action: { newTarget in
            // Only the first capture, deliberately - `sheetDetent` only
            // updates once a drag *settles* on a new detent, but this
            // geometry changes continuously *during* one, so without this
            // guard, every intermediate frame of a small -> large drag
            // would overwrite this with a mid-drag (not actually resting)
            // value, right up until the drag finally commits - exactly the
            // jitter a fixed target was supposed to avoid in the first
            // place. The one capture this allows happens right after this
            // view's first appearance, before any drag has had a chance to
            // start, while the sheet is genuinely still sitting at its
            // default small detent.
            guard measuredRestingIconTargetY == nil, sheetDetent == .fraction(Self.smallestSheetFraction) else { return }
            measuredRestingIconTargetY = newTarget
        })
        }
        // Presentations for this content's own actions. Nested here rather
        // than on MainDashboardView: on iPhone this view is itself always
        // inside a permanently-presented sheet (see the .bottomSheet case
        // below), and a second .sheet/.fullScreenCover attached to that same
        // outer view while one is already showing is an invalid
        // configuration - SwiftUI logs it and the presentation state wedges,
        // which is what made every button on iPhone stop responding. Nesting
        // these here presents them on top of the existing sheet instead of
        // competing with it. The flags themselves still live on
        // MainDashboardView (see its state block for why), so they survive
        // this view being torn down and rebuilt when iPad's layout swaps
        // between the side panel and the bottom panel.
        .sheet(isPresented: $showingAddFillUp) { NavigationStack { AddFillUpView(vehicle: vehicle, entryMode: fillUpEntryMode) }.roomySheetOnPad(duoLeadingWidth: duoLeadingSheetWidth) }
        .sheet(isPresented: $showingAddService) { NavigationStack { AddServiceView(vehicle: vehicle) }.roomySheetOnPad(duoLeadingWidth: duoLeadingSheetWidth) }
        .sheet(item: $eventToEdit) { ev in NavigationStack { switch ev { case .fillUp(let f): AddFillUpView(vehicle: vehicle, editingFillUp: f); case .service(let s): AddServiceView(vehicle: vehicle, editingService: s) } }.roomySheetOnPad(duoLeadingWidth: duoLeadingSheetWidth) }
        .sheet(isPresented: $showingAddVehicle) { NavigationStack { AddVehicleView() }.roomySheetOnPad(duoLeadingWidth: duoLeadingSheetWidth) }
        .sheet(item: $vehicleToEdit) { v in NavigationStack { AddVehicleView(editingVehicle: v) }.roomySheetOnPad(duoLeadingWidth: duoLeadingSheetWidth) }
        .sheet(isPresented: $showingArchivedVehicles) { ArchivedVehiclesView().roomySheetOnPad() }
        .sheet(item: $vehicleShareItem) { item in ActivityView(activityItems: [item.url]) }
        .alert("Delete \(vehicle.name)?", isPresented: $showingDeleteConfirmation) { Button("Cancel", role: .cancel) {}; Button("Delete", role: .destructive) { deleteVehicle() } } message: { Text("This will permanently delete this vehicle and all logs.") }
        .sheet(isPresented: $showingMonthlyReport) { NavigationStack { MonthlyReportView(month: monthlyReportMonth, vehicle: vehicle, isModal: true) }.roomySheetOnPad() }
        // A pop-up sheet rather than a full-screen cover on real iPad/phone:
        // Settings' sections are short (often a single toggle or picker),
        // and filling the whole screen with the sidebar for that left most
        // of it empty. Duo's side panel is the one exception, requested
        // directly - `.page` sizing there is still just a floating card far
        // short of the screen's actual width, nothing like how roomy the
        // same card is on a real iPad, so it read as cramped rather than
        // intentional. Two presentations sharing one Boolean's worth of
        // state (each gated so only one is ever actually true) rather than
        // a single modifier, since SwiftUI has no "sheet here, full-screen
        // cover there" switch on one trigger.
        .sheet(isPresented: Binding(
            get: { showingSettings && !isSidePanelLayout },
            set: { showingSettings = $0 }
        )) {
            SettingsView()
                .presentationCompactAdaptation(.fullScreenCover)
                .roomySheetOnPad()
        }
        .fullScreenCover(isPresented: Binding(
            get: { showingSettings && isSidePanelLayout },
            set: { showingSettings = $0 }
        )) {
            SettingsView(forcesRegularLayout: true)
        }
        // Trips and Charts stay full-screen: unlike Settings, their content
        // (a trip list, or wide charts) actually grows to use the screen.
        .fullScreenCover(isPresented: $showingTrips) {
            TripsListView(vehicle: vehicle)
        }
        .fullScreenCover(isPresented: $showingCharts) {
            VehicleChartsView(vehicle: vehicle)
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

    /// True whenever the pill isn't at its smallest detent on Duo's outer
    /// display - the icon row relocates into the reserved column there
    /// (see relocatedIconRow below), vertically stacked, rather than sitting
    /// inline in the header. True at every detent now, not just the large
    /// one - a horizontal row only ever fit inline at the small detent, but
    /// a vertical column fits in the header's own corner regardless of how
    /// tall the sheet is.
    private var iconRowIsRelocated: Bool { clusterWidth > 0 }

    /// The icon row when the pill isn't at its smallest detent, relocated
    /// into Duo's outer-display reserved column - same technique
    /// MainDashboardView uses for the map's own floating buttons
    /// (ignoresSafeArea, reaching past this view's own bounds via the
    /// ZStack sibling in body). Rendered here, inside the sheet's own
    /// content, rather than by MainDashboardView alongside the globe/locate
    /// buttons: confirmed on-device that a copy drawn in the *presenter*
    /// looked right but did nothing when tapped - a sheet's presentation
    /// always renders above its presenter. Living inside the sheet keeps
    /// these genuinely tappable at every detent.
    ///
    /// Positioned with `.offset`, not `.padding(.top:)` - padding changes a
    /// view's measured layout size, which compounded unpredictably through
    /// this column's nested Spacer/HStack/VStack scaffolding (confirmed
    /// on-device: raising the padding value by a fixed amount only ever
    /// moved the rendered icons by about half that amount, never 1:1, which
    /// took several rounds of on-device re-measurement to converge). Offset
    /// repositions the already-laid-out view without touching layout, which
    /// maps cleanly 1:1 to the real rendered position instead.
    ///
    /// `sheetTopY` is this whole view's own live frame (read via
    /// `GeometryReader` in `body`, in the `.global` coordinate space), not a
    /// value computed from the sheet's detent - a detent-based value is
    /// only correct once a drag settles on `.small` or `.large`; mid-drag,
    /// this view's frame already resizes continuously, confirmed via
    /// screen recording, but a detent-based offset stays pinned to
    /// whichever one was last committed, so the icon column either tracked
    /// the drag wrongly or didn't move at all, then snapped to the correct
    /// position the instant the detent flipped - a visible jump. Reading
    /// the live frame every layout pass instead means the fixed-target
    /// arithmetic below (`relocatedIconTargetAbsoluteY - sheetTopY`) is
    /// always correct for wherever the sheet actually is *this frame*, not
    /// just at the two settled endpoints, so there's nothing to snap.
    ///
    /// Untied from this view's own width entirely (unlike an earlier
    /// attempt that capped a "pill" width and positioned this relative to
    /// it) - a NavigationStack + .toolbar{} version was also tried, hoping
    /// the system would place these automatically, but it relocated them
    /// vertically only within this view's own trailing edge, not the true
    /// hardware column - still tied to wherever this view happened to end,
    /// which is exactly what this ignoresSafeArea approach avoids.
    ///
    /// Stacked vertically (see `quickIconColumn`) rather than in a row: a
    /// single 44pt-wide column fits inside the reserved 84pt column the same
    /// way the map's single button does, so it's centred the same way too -
    /// unlike an earlier horizontal layout, which was too wide to fit and
    /// had to hang its trailing edge off the column's own trailing edge
    /// instead.
    @ViewBuilder
    private func relocatedIconRow(sheetTopY: CGFloat) -> some View {
        if iconRowIsRelocated {
            VStack {
                HStack {
                    Spacer()
                    quickIconColumn
                        .offset(y: relocatedIconTargetAbsoluteY - sheetTopY)
                        .padding(.trailing, max(0, (clusterWidth - Self.relocatedIconColumnWidth) / 2 + Self.reservedColumnRightMargin - Self.sheetEdgeInset))
                }
                Spacer()
            }
            .ignoresSafeArea(.container, edges: .trailing)
        }
    }

    /// The absolute screen position the icon column always targets -
    /// centred within the resting/small pill specifically (the large detent
    /// just inherits whatever this value is, and has plenty of headroom
    /// either way).
    ///
    /// A hardcoded constant (413.5, re-measured by hand whenever the small
    /// pill's own height changed - e.g. once already when
    /// `smallestSheetFraction` moved 0.38 -> 0.42) worked as long as this
    /// row only ever appeared on one specific screen size, Duo's outer
    /// display. It broke the instant a second, differently-sized screen
    /// started relocating this row too (Duo's unfolded inner display,
    /// rotated into `.bottomSheet` - see
    /// `MainDashboardView.sheetIconClusterWidth(_:)`): the fixed pixel
    /// target put the column mostly off-screen there.
    ///
    /// Replacing it with a `smallestSheetFraction * screenHeight` estimate
    /// generalised to any screen size in principle, but confirmed on-device
    /// to still be off (uneven top/bottom margins) - the small pill's real
    /// rendered height isn't simply that fraction of the screen (see
    /// `MainDashboardView`'s own task history: it already needed a "more
    /// robust" floor on top of the plain fraction once, for the same
    /// reason). `measuredRestingIconTargetY`, captured straight off the
    /// sheet's own real geometry the moment it's actually seen resting at
    /// the small detent, sidesteps needing to know that relationship at
    /// all. The formula stays only as a same-frame fallback, so the column
    /// has *a* position (close, if not exact) before that first
    /// measurement lands rather than popping in from nowhere.
    private var relocatedIconTargetAbsoluteY: CGFloat {
        if let measuredRestingIconTargetY { return measuredRestingIconTargetY }
        let pillTop = screenHeight * (1 - Self.smallestSheetFraction)
        let pillHeight = screenHeight * Self.smallestSheetFraction
        return pillTop + (pillHeight - Self.relocatedIconColumnHeight) / 2
    }

    /// A small, fixed gap between this view's own `GeometryReader` frame
    /// and the true visible pill shape reported by the accessibility
    /// hierarchy - confirmed on-device: with no correction, the measured
    /// target landed the icon column's top margin at 35.7pt against a
    /// bottom margin of 53.3pt (should both be 44.5pt for a pill measuring
    /// {8, 369} by {450, 301pt} tall), i.e. ~8.8pt high. Most likely the
    /// system's own reserved space for `.presentationDragIndicator`,
    /// outside this view's own measured bounds but inside the pill shape
    /// the user actually sees - a fixed system-chrome height, not
    /// something that should scale with screen size, unlike the error the
    /// measurement itself replaced.
    private static let measuredFrameCorrection: CGFloat = 8.8

    /// Mirrors `MainDashboardView.smallestSheetFraction` - duplicated, not
    /// shared, for the same reason `reservedColumnRightMargin` below is:
    /// different type, no common ancestor to hang a shared constant off of.
    private static let smallestSheetFraction: CGFloat = 0.42

    /// `quickIconColumn`'s own rendered height: 4 buttons at
    /// `relocatedIconColumnWidth` (44pt, square/circular) plus the VStack's
    /// own 12pt spacing between them (3 gaps).
    private static let relocatedIconColumnHeight: CGFloat = 4 * 44 + 3 * 12

    /// A single icon button's own width (44pt) - see `relocatedIconRow`'s
    /// centring maths, which mirrors MainDashboardView's for the map's
    /// floating buttons now that this column is narrow enough to fit.
    private static let relocatedIconColumnWidth: CGFloat = 44

    /// Same correction and same reasoning as
    /// MainDashboardView.reservedColumnRightMargin - the reserved column
    /// isn't flush against the true trailing edge, so a naive centring
    /// lands ~6pt too far right. Duplicated here (not shared) since this is
    /// a different type with no common ancestor to hang a shared constant
    /// off of.
    private static let reservedColumnRightMargin: CGFloat = 6

    /// This view's content sits inside a `.sheet()` presentation, which the
    /// system insets a fixed margin from every screen edge on its own -
    /// `.ignoresSafeArea(.container, edges: .trailing)` above reaches past
    /// this view's normal safe area, but not past that separate presentation
    /// margin, since it isn't a safe area at all. The map's globe/locate
    /// buttons don't have this problem (they're drawn by the presenter, not
    /// inside the sheet), so centring both against the same trailing-edge
    /// column left this one ~8pt further left. Confirmed on-device: the icon
    /// column measured ~7.6pt left of the map buttons' column before this
    /// correction.
    private static let sheetEdgeInset: CGFloat = 8

    private var headerBar: some View {
        HStack(spacing: 16) {
            vehicleMenuLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                // When relocated, quickIconRow isn't this HStack's sibling
                // any more - it's a separately-positioned floating column
                // (see relocatedIconRow), so this HStack's own vertical
                // centering no longer does anything to align the two. The
                // label's own text is only 26.3pt tall against the icon
                // column's 44pt-tall circles, so matching their *tops*
                // leaves the label's visual centre sitting ~9pt higher than
                // the icons' - a flat +9 is what centres them instead,
                // confirmed on-device. Not tied to the icon column's own
                // offset the way an earlier version was: that offset now
                // targets a fixed *absolute*
                // screen position that's completely decoupled from
                // headerBar's own (always-24) structural top padding, so
                // there's no shared "baseline" left between the two to
                // stay in sync with - this label's own +9 is a
                // self-contained correction for its height difference from
                // a 44pt circle, nothing else, and stays correct regardless
                // of whatever the icon column's own offset is tuned to.
                //
                // .offset, not .padding(.top:) - a first attempt used
                // padding, which pushed the visible text down correctly but
                // also grew headerBar's own measured height by the same
                // amount (padding adds to a view's layout size, which an
                // HStack's sibling rows - here, every row in the ScrollView
                // below - then have to flow around). That silently pushed
                // "View Trends & Charts" back off the bottom of the pill,
                // reintroducing the exact cutoff the small-pill-height fix
                // above was for, confirmed on-device. offset repositions
                // the rendered content without changing the space it
                // reserves, so nothing downstream moves.
                .offset(y: iconRowIsRelocated ? 9 : 0)
            if !iconRowIsRelocated && !hidesInlineIcons {
                quickIconRow
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
    }

    private var vehicleMenuLabel: some View {
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(vehicle.name)
                        .font(.title2.weight(.heavy))
                        .foregroundColor(.primary)
                        // Single line, shrinking a long name to fit rather than
                        // wrapping it - wrapping pushed the header taller and
                        // crowded the row below it.
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
    }

    /// A single quick-action icon button, shared by `quickIconButtons`
    /// below - Liquid Glass where available, explicitly shaped as a
    /// `Circle` (see `mapControlButton`'s comment: `.buttonStyle(.glass)`
    /// sizes its capsule to the label's own content, which rendered as a
    /// visibly different-width oval per icon instead of a uniform circle -
    /// sizing the label to a fixed 44x44 frame *before* the glassEffect is
    /// what actually forces a true circle). `.buttonStyle(.plain)` in the
    /// fallback branch is what makes an explicit `foregroundStyle(.primary)`
    /// on the label actually stick there: left off, the default button
    /// style tinted these with the accent colour instead (visible on-device
    /// as the plus/share/gear icons rendering blue while the map icon,
    /// whose foregroundStyle branches on `newReportMonth`, happened to
    /// still read correctly only when that branch resolved to `.primary`).
    @ViewBuilder
    private func quickIconButton(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                label()
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            Button(action: action) { label() }
                .frame(width: 44, height: 44)
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
        }
    }

    /// The 4 buttons shared by `quickIconRow` (inline, horizontal) and
    /// `quickIconColumn` (relocated into Duo's outer-display column,
    /// vertical) - same buttons, just arranged differently by their
    /// container.
    @ViewBuilder
    private var quickIconButtons: some View {
        quickIconButton(action: { showingAddVehicle = true }) {
            Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary)
        }
        quickIconButton(action: {
            if let month = newReportMonth {
                onAcknowledgeReport()
                monthlyReportMonth = month
                showingMonthlyReport = true
            } else {
                showingTrips = true
            }
        }) {
            Image(systemName: "map.fill").font(.system(size: 20))
                .foregroundStyle(newReportMonth != nil ? Color.accentColor : .primary)
                .symbolEffect(.pulse, options: .repeating, isActive: newReportMonth != nil)
        }
        .accessibilityIdentifier("TripsButton")
        quickIconButton(action: { shareVehicleForLogging() }) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 20)).foregroundStyle(.primary)
        }
        .accessibilityIdentifier("ShareVehicleButton")
        .accessibilityLabel("Share \(vehicle.name) for logging")
        quickIconButton(action: { showingSettings = true }) {
            Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundStyle(.primary)
        }
    }

    /// Used inline in the header everywhere the icon row isn't relocated (a
    /// normal iPhone, iPad, or Duo's inner display) - also used by
    /// `MainDashboardView.leadingIconRow(_:)` via a second
    /// `DashboardSheetContent` instance, the same way `quickIconColumn`
    /// already is by `sidePanelIconColumn`, which is why this isn't
    /// `private` either.
    var quickIconRow: some View {
        HStack(spacing: 12) { quickIconButtons }
    }

    /// Same 4 buttons stacked vertically instead of in a row - used by
    /// `relocatedIconRow` (matching the vertical column the system uses for
    /// its own status/toolbar icons on Duo's outer display) and, via a
    /// second `DashboardSheetContent` instance built just to read this one
    /// property off of, by `MainDashboardView.sidePanel` for Duo's unfolded
    /// inner display - not `private` for that second case.
    var quickIconColumn: some View {
        VStack(spacing: 12) { quickIconButtons }
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
                    .hoverEffect(.highlight)
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
            .hoverEffect(.highlight)
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

    private func deleteVehicle() {
        modelContext.delete(vehicle)
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


