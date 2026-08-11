import WidgetKit
import SwiftUI
import FuelLogShared

// MARK: - Spend Widget

struct SpendEntry: TimelineEntry {
    let date: Date
    let vehicle: FuelLogWidgetVehicle?
}

struct SpendProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SpendEntry {
        SpendEntry(date: Date(), vehicle: .placeholder)
    }

    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> SpendEntry {
        makeEntry(for: configuration)
    }

    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<SpendEntry> {
        let entry = makeEntry(for: configuration)
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func makeEntry(for configuration: VehicleSelectionIntent) -> SpendEntry {
        let snapshot = WidgetSnapshotStore.load()
        return SpendEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: snapshot))
    }
}

struct SpendWidgetView: View {
    let entry: SpendEntry

    var body: some View {
        Group {
            if let vehicle = entry.vehicle {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("This Month")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Text(WidgetFormatting.currency(vehicle.thisMonthSpend, raw: vehicle.currencyRaw))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text("Fuel & fuel add-ons")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Text(vehicle.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(entry.vehicle == nil ? "Add a vehicle." : "No fill-ups this month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SpendWidget: Widget {
    static let kind = "SpendWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: SpendProvider()) { entry in
            SpendWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        }
        .configurationDisplayName("Monthly Spend")
        .description("Shows how much you've spent on fuel this month.")
        .supportedFamilies([.systemSmall])
    }
}
