import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - Shared per-vehicle entry/provider

struct VehicleStatEntry: TimelineEntry {
    let date: Date
    let vehicle: FuelLogWidgetVehicle?
}

private func makeVehicleStatEntry(for configuration: VehicleSelectionIntent) -> VehicleStatEntry {
    let snapshot = WidgetSnapshotStore.load()
    return VehicleStatEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: snapshot))
}

struct OdometerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VehicleStatEntry { VehicleStatEntry(date: Date(), vehicle: .placeholder) }
    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> VehicleStatEntry { makeVehicleStatEntry(for: configuration) }
    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<VehicleStatEntry> {
        let refresh = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date().addingTimeInterval(6 * 3600)
        return Timeline(entries: [makeVehicleStatEntry(for: configuration)], policy: .after(refresh))
    }
}

struct RecencyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VehicleStatEntry { VehicleStatEntry(date: Date(), vehicle: .placeholder) }
    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> VehicleStatEntry { makeVehicleStatEntry(for: configuration) }
    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<VehicleStatEntry> {
        // Refresh at the next midnight so "days since" stays current.
        let start = Calendar.current.startOfDay(for: Date())
        let refresh = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86400)
        return Timeline(entries: [makeVehicleStatEntry(for: configuration)], policy: .after(refresh))
    }
}

// MARK: - Odometer Widget

struct OdometerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VehicleStatEntry

    private var odoText: String? {
        guard let v = entry.vehicle, let odo = v.lastOdometer else { return nil }
        return WidgetFormatting.wholeNumber(odo)
    }
    private var unit: String { WidgetFormatting.distanceUnitSuffix(entry.vehicle?.odometerUnitRaw ?? OdometerUnit.miles.rawValue) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryInline ? .center : .leading)
            .fuelLogWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            if let odo = odoText { Label("\(odo) \(unit)", systemImage: "gauge.open.with.lines.needle.33percent") }
            else { Label("No odometer", systemImage: "gauge.open.with.lines.needle.33percent") }
        case .accessoryCircular:
            VStack(spacing: 0) {
                if let odo = odoText {
                    Text(odo).font(.system(size: 18, weight: .bold, design: .rounded)).minimumScaleFactor(0.4).lineLimit(1)
                    Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Image(systemName: "gauge.open.with.lines.needle.33percent").font(.title3) }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Odometer", systemImage: "gauge.open.with.lines.needle.33percent")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(odoText.map { "\($0) \(unit)" } ?? "-").font(.headline)
                if let date = entry.vehicle?.lastFillUpDate {
                    Text("Filled \(WidgetFormatting.daysAgoText(date).lowercased())").font(.caption2).foregroundStyle(.secondary)
                }
            }
        default:
            homeView
        }
    }

    @ViewBuilder private var homeView: some View {
        if let vehicle = entry.vehicle, let odo = odoText {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.open.with.lines.needle.33percent").font(.footnote).foregroundStyle(.secondary)
                    Text("Odometer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(odo).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                Text(unit).font(.caption).foregroundStyle(.secondary)
                if let date = vehicle.lastFillUpDate {
                    Text("Filled \(WidgetFormatting.daysAgoText(date).lowercased())").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(vehicle.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "gauge.open.with.lines.needle.33percent").font(.title2).foregroundStyle(.secondary)
                Text(entry.vehicle == nil ? "Add a vehicle." : "Log a fill-up with an odometer reading.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OdometerWidget: Widget {
    static let kind = "OdometerWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: OdometerProvider()) { entry in
            OdometerWidgetView(entry: entry)
        }
        .configurationDisplayName("Odometer")
        .description("Your vehicle's latest odometer reading.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Fill-Up Recency Widget

struct RecencyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VehicleStatEntry

    private var daysSince: Int? {
        guard let date = entry.vehicle?.lastFillUpDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day
    }
    private var recencyText: String {
        guard let date = entry.vehicle?.lastFillUpDate else { return "No fill-ups" }
        return WidgetFormatting.daysAgoText(date)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryInline ? .center : .leading)
            .fuelLogWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            if entry.vehicle?.lastFillUpDate != nil { Label("Fueled \(recencyText.lowercased())", systemImage: "fuelpump") }
            else { Label("No fill-ups yet", systemImage: "fuelpump") }
        case .accessoryCircular:
            VStack(spacing: 0) {
                if let days = daysSince {
                    Text("\(max(0, days))").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(days == 1 ? "day" : "days").font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Image(systemName: "fuelpump").font(.title3) }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Last Fill-Up", systemImage: "fuelpump").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(recencyText).font(.headline)
                if let name = entry.vehicle?.name { Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        default:
            homeView
        }
    }

    @ViewBuilder private var homeView: some View {
        if let vehicle = entry.vehicle {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "fuelpump").font(.footnote).foregroundStyle(.secondary)
                    Text("Last Fill-Up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(recencyText).font(.system(size: 26, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                if let days = daysSince, days >= 10 {
                    Text("Time to refuel?").font(.caption2).foregroundStyle(.orange)
                }
                Text(vehicle.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "fuelpump").font(.title2).foregroundStyle(.secondary)
                Text("Add a vehicle.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FillUpRecencyWidget: Widget {
    static let kind = "FillUpRecencyWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: RecencyProvider()) { entry in
            RecencyWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Fill-Up")
        .description("How long since you last fueled up.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
