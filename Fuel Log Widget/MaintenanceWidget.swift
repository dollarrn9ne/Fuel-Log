import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - Maintenance Widget

struct MaintenanceEntry: TimelineEntry {
    let date: Date
    let vehicle: FuelLogWidgetVehicle?
    let hasAnyVehicle: Bool
}

struct MaintenanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MaintenanceEntry {
        MaintenanceEntry(date: Date(), vehicle: .placeholder, hasAnyVehicle: true)
    }

    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> MaintenanceEntry {
        makeEntry(for: configuration)
    }

    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<MaintenanceEntry> {
        let entry = makeEntry(for: configuration)
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func makeEntry(for configuration: VehicleSelectionIntent) -> MaintenanceEntry {
        let snapshot = WidgetSnapshotStore.load()
        let vehicle = selectedVehicle(from: configuration, fallback: snapshot)
        return MaintenanceEntry(date: Date(), vehicle: vehicle, hasAnyVehicle: (snapshot?.vehicles.isEmpty == false))
    }
}

struct MaintenanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MaintenanceEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryInline ? .center : .leading)
            .fuelLogWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inlineView
        case .accessoryCircular: circularView
        case .accessoryRectangular: rectangularView
        default:
            if let vehicle = entry.vehicle {
                maintenanceContent(vehicle)
            } else {
                emptyContent
            }
        }
    }

    @ViewBuilder private var inlineView: some View {
        if let vehicle = entry.vehicle {
            if vehicle.isMaintenanceDue {
                Label("Service due", systemImage: "exclamationmark.triangle.fill")
            } else if let date = vehicle.maintenanceNextDate {
                Label("Service \(date.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "wrench.and.screwdriver.fill")
            } else {
                Label("Service up to date", systemImage: "wrench.and.screwdriver.fill")
            }
        } else {
            Label("Add a vehicle", systemImage: "car.fill")
        }
    }

    @ViewBuilder private var circularView: some View {
        if let vehicle = entry.vehicle {
            if vehicle.isMaintenanceDue {
                VStack(spacing: 0) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3)
                    Text("Due").font(.system(size: 10, weight: .semibold))
                }
            } else {
                Gauge(value: WidgetFormatting.maintenanceProgress(vehicle)) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                } currentValueLabel: {
                    if let remaining = vehicle.maintenanceRemainingDistance {
                        Text("\(Int(max(0, remaining)))").minimumScaleFactor(0.4).lineLimit(1)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill")
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        } else {
            Image(systemName: "car.fill").font(.title3)
        }
    }

    @ViewBuilder private var rectangularView: some View {
        if let vehicle = entry.vehicle {
            VStack(alignment: .leading, spacing: 2) {
                Label(vehicle.name, systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if vehicle.isMaintenanceDue {
                    Text("Maintenance Due").font(.headline).foregroundStyle(.red)
                } else if let date = vehicle.maintenanceNextDate {
                    Text(date, format: .dateTime.month(.abbreviated).day()).font(.headline)
                    if let remaining = vehicle.maintenanceRemainingDistance {
                        Text("\(WidgetFormatting.remainingDistanceText(remaining, odometerUnitRaw: vehicle.odometerUnitRaw)) to go")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("All set").font(.headline)
                }
            }
        } else {
            Label("Add a vehicle", systemImage: "car.fill").font(.caption)
        }
    }

    @ViewBuilder
    private func maintenanceContent(_ vehicle: FuelLogWidgetVehicle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(vehicle.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if vehicle.isMaintenanceDue {
                Label("Maintenance Due", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                if let remaining = vehicle.maintenanceRemainingDistance {
                    Text("\(WidgetFormatting.remainingDistanceText(max(0, remaining), odometerUnitRaw: vehicle.odometerUnitRaw)) overdue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let date = vehicle.maintenanceNextDate {
                Text(date, format: .dateTime.month(.abbreviated).day())
                    .font(.title2.weight(.bold))
                if let remaining = vehicle.maintenanceRemainingDistance {
                    Text("\(WidgetFormatting.remainingDistanceText(remaining, odometerUnitRaw: vehicle.odometerUnitRaw)) to go")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("All set")
                    .font(.headline)
            }

        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "car.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(entry.hasAnyVehicle ? "Select a vehicle to see maintenance." : "Add a vehicle to see maintenance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MaintenanceWidget: Widget {
    static let kind = "MaintenanceWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: MaintenanceProvider()) { entry in
            MaintenanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Maintenance")
        .description("Shows when your next service is due — whichever comes first: distance or time.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
