import WidgetKit
import SwiftUI
import ActivityKit
import FuelLogShared

// MARK: - Live Activity UI

struct FuelLogLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FuelFillUpAttributes.self) { context in
            lockScreenView(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(context.attributes.vehicleName, systemImage: "fuelpump.fill")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("Fuel Fill-Up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(totalText(context.state))
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        if context.state.volume > 0 {
                            Label("\(volumeText(context.state.volume)) \(unitText(context.state))", systemImage: "fuelpump.fill")
                        }
                        if context.state.pricePerUnit > 0 {
                            Label("\(priceText(context.state.pricePerUnit))", systemImage: "tag.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "fuelpump.fill")
            } compactTrailing: {
                Text(totalText(context.state))
                    .font(.caption2.weight(.semibold))
            } minimal: {
                Image(systemName: "fuelpump.fill")
            }
        }
        .configurationDisplayName("Fuel Fill-Up")
        .description("Tracks your running fuel cost while you log a fill-up.")
    }

    private func lockScreenView(_ context: ActivityViewContext<FuelFillUpAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.vehicleName, systemImage: "fuelpump.fill")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(totalText(context.state))
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                if context.state.volume > 0 {
                    Text("\(volumeText(context.state.volume)) \(unitText(context.state))")
                }
                if context.state.pricePerUnit > 0 {
                    Text("\u{00D7} \(priceText(context.state.pricePerUnit))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func totalText(_ state: FuelFillUpAttributes.ContentState) -> String {
        WidgetFormatting.currency(state.totalCost, raw: state.currencyRaw)
    }

    private func volumeText(_ volume: Double) -> String {
        volume.formatted(.number.precision(.fractionLength(1...2)))
    }

    private func priceText(_ price: Double) -> String {
        price.formatted(.number.precision(.fractionLength(2...3)))
    }

    private func unitText(_ state: FuelFillUpAttributes.ContentState) -> String {
        FuelUnit(rawValue: state.unitRaw)?.rawValue ?? "units"
    }
}
