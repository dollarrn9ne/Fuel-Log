import WidgetKit
import SwiftUI
import AppIntents
import FuelLogShared

// MARK: - Widget Bundle

@main
struct FuelLogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MaintenanceWidget()
        EfficiencyWidget()
        SpendWidget()
        AllVehiclesWidget()
        OdometerWidget()
        FillUpRecencyWidget()
        LastPriceWidget()
        EfficiencyTrendWidget()
        FuelLogLiveActivity()
        if #available(iOS 18.0, *) {
            LogFuelControl()
        }
    }
}

// MARK: - Quick Log Control

/// A Control Center / Lock Screen / Action-button control that opens the app
/// straight to the Add Fuel screen.
@available(iOS 18.0, *)
struct LogFuelControl: ControlWidget {
    static let kind = "com.motosung.fuellog.logFuelControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: LogFuelControlIntent()) {
                Label("Log Fuel", systemImage: "fuelpump.fill")
            }
        }
        .displayName("Log Fuel")
        .description("Quickly add a fuel fill-up in Fuel Log.")
    }
}

/// Opens the app and leaves a flag the app reads to present Add Fuel. (Custom URL
/// schemes aren't allowed with OpenURLIntent, so we route via the App Group.)
struct LogFuelControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Fuel"
    static let description = IntentDescription("Opens Fuel Log to add a fill-up.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: FuelLogWidgetSnapshot.appGroupIdentifier)?
            .set("addFuel", forKey: FuelLogWidgetSnapshot.pendingActionKey)
        return .result()
    }
}
