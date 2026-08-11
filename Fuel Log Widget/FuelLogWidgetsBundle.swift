import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - Widget Bundle

@main
struct FuelLogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MaintenanceWidget()
        EfficiencyWidget()
        SpendWidget()
        FuelLogLiveActivity()
    }
}
