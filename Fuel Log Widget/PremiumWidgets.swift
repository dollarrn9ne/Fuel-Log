import WidgetKit
import SwiftUI
import Charts
import FuelLogShared

// MARK: - Shared helpers

private func shortFuelUnit(_ raw: String) -> String {
    switch FuelUnit(rawValue: raw) ?? .gallons {
    case .gallons: return "gal"
    case .liters: return "L"
    case .kwh: return "kWh"
    }
}

// Reuses VehicleStatEntry (defined in OdometerWidget.swift).

struct LastPriceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VehicleStatEntry { VehicleStatEntry(date: Date(), vehicle: .placeholder) }
    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> VehicleStatEntry {
        VehicleStatEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: WidgetSnapshotStore.load()))
    }
    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<VehicleStatEntry> {
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        return Timeline(entries: [VehicleStatEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: WidgetSnapshotStore.load()))], policy: .after(refresh))
    }
}

struct TrendProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VehicleStatEntry { VehicleStatEntry(date: Date(), vehicle: .placeholder) }
    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> VehicleStatEntry {
        VehicleStatEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: WidgetSnapshotStore.load()))
    }
    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<VehicleStatEntry> {
        let refresh = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date().addingTimeInterval(3 * 3600)
        return Timeline(entries: [VehicleStatEntry(date: Date(), vehicle: selectedVehicle(from: configuration, fallback: WidgetSnapshotStore.load()))], policy: .after(refresh))
    }
}

// MARK: - Last Price Widget

struct LastPriceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VehicleStatEntry

    private var priceText: String? {
        guard let v = entry.vehicle, let price = v.lastPricePerUnit else { return nil }
        return WidgetFormatting.currency(price, raw: v.currencyRaw)
    }
    private var perUnit: String { "/\(shortFuelUnit(entry.vehicle?.fuelUnitRaw ?? FuelUnit.gallons.rawValue))" }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryInline ? .center : .leading)
            .fuelLogWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label(priceText.map { "\($0)\(perUnit)" } ?? "No price", systemImage: "tag.fill")
        case .accessoryCircular:
            VStack(spacing: 0) {
                if let price = priceText {
                    Text(price).font(.system(size: 16, weight: .bold, design: .rounded)).minimumScaleFactor(0.4).lineLimit(1)
                    Text(perUnit).font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Image(systemName: "tag.fill").font(.title3) }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Last Price", systemImage: "tag.fill").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(priceText.map { "\($0)\(perUnit)" } ?? "—").font(.headline)
                if let name = entry.vehicle?.name { Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    @ViewBuilder private var smallView: some View {
        if let vehicle = entry.vehicle, let price = priceText {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill").font(.footnote).foregroundStyle(.secondary)
                    Text("Last Price").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(price).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                Text(perUnit).font(.caption).foregroundStyle(.secondary)
                Text(vehicle.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "tag.fill").font(.title2).foregroundStyle(.secondary)
                Text(entry.vehicle == nil ? "Add a vehicle." : "Log a fill-up to see price.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var mediumView: some View {
        if let vehicle = entry.vehicle {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Last Price", systemImage: "tag.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(priceText.map { "\($0)\(perUnit)" } ?? "—").font(.system(size: 26, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    Text(vehicle.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("This Year").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ytdRow(label: "Fuel", value: vehicle.thisYearFuelSpend, raw: vehicle.currencyRaw, color: .blue)
                    ytdRow(label: "Service", value: vehicle.thisYearServiceSpend, raw: vehicle.currencyRaw, color: .orange)
                    Divider()
                    ytdRow(label: "Total", value: vehicle.thisYearFuelSpend + vehicle.thisYearServiceSpend, raw: vehicle.currencyRaw, color: .primary, bold: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            smallView
        }
    }

    @ViewBuilder private func ytdRow(label: String, value: Double, raw: String, color: Color, bold: Bool = false) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption)
            Spacer(minLength: 4)
            Text(WidgetFormatting.currency(value, raw: raw)).font(bold ? .caption.weight(.bold) : .caption).monospacedDigit()
        }
    }
}

struct LastPriceWidget: Widget {
    static let kind = "LastPriceWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: LastPriceProvider()) { entry in
            LastPriceWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Price / Spend")
        .description("The most recent price you paid, plus this year's fuel and service spend.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Efficiency Trend Widget

struct EfficiencyTrendWidgetView: View {
    let entry: VehicleStatEntry

    var body: some View {
        Group {
            if let vehicle = entry.vehicle, vehicle.recentEfficiencyPoints.count >= 2 {
                let points = vehicle.recentEfficiencyPoints
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Efficiency Trend", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if let eff = vehicle.averageEfficiency {
                            Text("\(WidgetFormatting.efficiencyValue(vehicle, efficiency: eff)) \(WidgetFormatting.efficiencyUnitLabel(vehicle))")
                                .font(.caption.weight(.bold))
                        }
                    }
                    Chart(Array(points.enumerated()), id: \.offset) { index, value in
                        LineMark(x: .value("Fill", index), y: .value("Efficiency", value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.pink)
                        AreaMark(x: .value("Fill", index), y: .value("Efficiency", value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Color.pink.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    Text(vehicle.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(.secondary)
                    Text(entry.vehicle == nil ? "Add a vehicle." : "Log a few full-tank fill-ups to see a trend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}

struct EfficiencyTrendWidget: Widget {
    static let kind = "EfficiencyTrendWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: VehicleSelectionIntent.self, provider: TrendProvider()) { entry in
            EfficiencyTrendWidgetView(entry: entry)
        }
        .configurationDisplayName("Efficiency Trend")
        .description("A sparkline of your recent fuel efficiency.")
        .supportedFamilies([.systemMedium])
    }
}
