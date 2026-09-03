import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - Efficiency Widget

struct EfficiencyEntry: TimelineEntry {
    let date: Date
    let vehicle: FuelLogWidgetVehicle?
}

struct EfficiencyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> EfficiencyEntry {
        EfficiencyEntry(date: Date(), vehicle: .placeholder)
    }

    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> EfficiencyEntry {
        makeEntry(for: configuration)
    }

    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<EfficiencyEntry> {
        let entry = makeEntry(for: configuration)
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func makeEntry(for configuration: VehicleSelectionIntent) -> EfficiencyEntry {
        let snapshot = WidgetSnapshotStore.load()
        return EfficiencyEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: snapshot))
    }
}

struct EfficiencyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: EfficiencyEntry

    private var valueText: String? {
        guard let v = entry.vehicle, let eff = v.averageEfficiency else { return nil }
        return WidgetFormatting.efficiencyValue(v, efficiency: eff)
    }

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
        default: homeView
        }
    }

    @ViewBuilder private var homeView: some View {
        if let vehicle = entry.vehicle, let value = valueText {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "fuelpump.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Efficiency")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(WidgetFormatting.efficiencyUnitLabel(vehicle))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(vehicle.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "fuelpump.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(entry.vehicle == nil ? "Add a vehicle." : "Log two full-tank fill-ups to see efficiency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var inlineView: some View {
        if let vehicle = entry.vehicle, let value = valueText {
            Label("\(value) \(WidgetFormatting.efficiencyUnitLabel(vehicle))", systemImage: "fuelpump.fill")
        } else {
            Label("No efficiency yet", systemImage: "fuelpump.fill")
        }
    }

    @ViewBuilder private var circularView: some View {
        VStack(spacing: 0) {
            if let vehicle = entry.vehicle, let value = valueText {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(WidgetFormatting.efficiencyUnitLabel(vehicle))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Image(systemName: "fuelpump.fill").font(.title3)
            }
        }
    }

    @ViewBuilder private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Efficiency", systemImage: "fuelpump.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let vehicle = entry.vehicle, let value = valueText {
                Text("\(value) \(WidgetFormatting.efficiencyUnitLabel(vehicle))")
                    .font(.headline)
                Text(vehicle.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Log two full tanks").font(.caption)
            }
        }
    }
}

struct EfficiencyWidget: Widget {
    static let kind = "EfficiencyWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: EfficiencyProvider()) { entry in
            EfficiencyWidgetView(entry: entry)
        }
        .configurationDisplayName("Efficiency")
        .description("Shows your vehicle's average fuel or electric efficiency.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
