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
    @Environment(\.widgetFamily) private var family
    let entry: SpendEntry

    private var spendText: String? {
        guard let v = entry.vehicle else { return nil }
        return WidgetFormatting.currency(v.thisMonthSpend, raw: v.currencyRaw)
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
        if let vehicle = entry.vehicle, let spend = spendText {
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

                Text(spend)
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

    @ViewBuilder private var inlineView: some View {
        if let spend = spendText {
            Label("\(spend) this month", systemImage: "dollarsign.circle.fill")
        } else {
            Label("No spend yet", systemImage: "dollarsign.circle.fill")
        }
    }

    @ViewBuilder private var circularView: some View {
        VStack(spacing: 0) {
            if let spend = spendText {
                Text(spend)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Text("mo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "dollarsign.circle.fill").font(.title3)
            }
        }
    }

    @ViewBuilder private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("This Month", systemImage: "dollarsign.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let vehicle = entry.vehicle, let spend = spendText {
                Text(spend).font(.headline)
                Text(vehicle.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No fill-ups this month").font(.caption)
            }
        }
    }
}

struct SpendWidget: Widget {
    static let kind = "SpendWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: SpendProvider()) { entry in
            SpendWidgetView(entry: entry)
        }
        .configurationDisplayName("Monthly Spend")
        .description("Shows how much you've spent on fuel this month.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
