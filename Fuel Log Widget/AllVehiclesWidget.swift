import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - All Vehicles Summary Widget

struct AllVehiclesEntry: TimelineEntry {
    let date: Date
    let vehicles: [FuelLogWidgetVehicle]
}

struct AllVehiclesProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllVehiclesEntry {
        AllVehiclesEntry(date: Date(), vehicles: [.placeholder])
    }

    func getSnapshot(in context: Context, completion: @escaping (AllVehiclesEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllVehiclesEntry>) -> Void) {
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        completion(Timeline(entries: [makeEntry()], policy: .after(refresh)))
    }

    private func makeEntry() -> AllVehiclesEntry {
        AllVehiclesEntry(date: Date(), vehicles: WidgetSnapshotStore.load()?.vehicles ?? [])
    }
}

struct AllVehiclesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AllVehiclesEntry

    private var maxRows: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        Group {
            if entry.vehicles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "car.2.fill").font(.title2).foregroundStyle(.secondary)
                    Text("Add a vehicle to see your garage.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "car.2.fill").font(.caption).foregroundStyle(.secondary)
                        Text("Garage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(entry.vehicles.prefix(maxRows)) { vehicle in
                        row(vehicle)
                        if vehicle.id != entry.vehicles.prefix(maxRows).last?.id {
                            Divider()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .fuelLogWidgetBackground(family)
    }

    @ViewBuilder private func row(_ vehicle: FuelLogWidgetVehicle) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vehicle.isMaintenanceDue ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(vehicle.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(WidgetFormatting.currency(vehicle.thisMonthSpend, raw: vehicle.currencyRaw) + " this month")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let eff = vehicle.averageEfficiency {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(WidgetFormatting.efficiencyValue(vehicle, efficiency: eff))
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                    Text(WidgetFormatting.efficiencyUnitLabel(vehicle))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AllVehiclesWidget: Widget {
    static let kind = "AllVehiclesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: AllVehiclesProvider()) { entry in
            AllVehiclesWidgetView(entry: entry)
        }
        .configurationDisplayName("Garage Summary")
        .description("Every vehicle's monthly spend, efficiency, and service status at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
