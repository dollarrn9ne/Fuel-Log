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
    let entry: EfficiencyEntry

    var body: some View {
        Group {
            if let vehicle = entry.vehicle, let efficiency = vehicle.averageEfficiency {
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

                    Text(WidgetFormatting.efficiencyValue(vehicle, efficiency: efficiency))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct EfficiencyWidget: Widget {
    static let kind = "EfficiencyWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: EfficiencyProvider()) { entry in
            EfficiencyWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        }
        .configurationDisplayName("Efficiency")
        .description("Shows your vehicle's average fuel or electric efficiency.")
        .supportedFamilies([.systemSmall])
    }
}
