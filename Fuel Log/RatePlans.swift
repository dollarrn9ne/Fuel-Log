import SwiftUI

// MARK: - Rate plan

/// A household electricity rate, used to price home charging: either one fixed
/// price per kWh, or a time-of-use plan with a peak and an off-peak price.
///
/// Stored per device (see `RatePlanStore`) rather than as a database model:
/// a plan is configuration, not a log, and a new synced entity would put the
/// CloudKit schema at risk for what is a handful of numbers. Each charge
/// records the blended price it ended up with, so totals never depend on a
/// plan still existing.
struct RatePlan: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case fixed = "Fixed Rate"
        case timeOfUse = "Time of Use"
        var id: String { rawValue }
    }

    var id = UUID()
    var name: String
    var kind: Kind = .fixed
    /// Price per kWh for a fixed plan.
    var fixedRate: Double = 0
    var peakRate: Double = 0
    var offPeakRate: Double = 0
    /// The off-peak window, as minutes after midnight. May wrap past midnight
    /// (21:00 -> 06:00 is the common overnight window).
    var offPeakStartMinute: Int = 21 * 60
    var offPeakEndMinute: Int = 6 * 60
    /// Many utilities bill the whole weekend at the off-peak price.
    var weekendsAllOffPeak: Bool = false

    /// The result of pricing one session against a plan.
    struct Breakdown: Equatable {
        var offPeakKWh: Double
        var peakKWh: Double
        var cost: Double
        var blendedRate: Double
    }

    /// Whether the given moment is billed at the off-peak price.
    func isOffPeak(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard kind == .timeOfUse else { return false }
        if weekendsAllOffPeak, calendar.isDateInWeekend(date) { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if offPeakStartMinute == offPeakEndMinute { return false }
        if offPeakStartMinute < offPeakEndMinute {
            return minute >= offPeakStartMinute && minute < offPeakEndMinute
        }
        // Wraps past midnight.
        return minute >= offPeakStartMinute || minute < offPeakEndMinute
    }

    /// Prices a session. The energy is assumed to flow at a constant power over
    /// the session, so the off-peak share of the kWh equals the off-peak share
    /// of the minutes. Without a duration the whole session is judged by the
    /// moment it started.
    func breakdown(kWh: Double, start: Date, minutes: Int?, calendar: Calendar = .current) -> Breakdown {
        guard kWh > 0 else { return Breakdown(offPeakKWh: 0, peakKWh: 0, cost: 0, blendedRate: 0) }
        switch kind {
        case .fixed:
            return Breakdown(offPeakKWh: 0, peakKWh: kWh, cost: kWh * fixedRate, blendedRate: fixedRate)
        case .timeOfUse:
            let fraction: Double
            if let minutes, minutes > 0 {
                // Sampled at each minute's midpoint; capped so a typo can't loop for days.
                let count = min(minutes, 60 * 48)
                var off = 0
                for i in 0..<count where isOffPeak(start.addingTimeInterval((Double(i) + 0.5) * 60), calendar: calendar) { off += 1 }
                fraction = Double(off) / Double(count)
            } else {
                fraction = isOffPeak(start, calendar: calendar) ? 1 : 0
            }
            let offKWh = kWh * fraction
            let peakKWh = kWh - offKWh
            let cost = offKWh * offPeakRate + peakKWh * peakRate
            return Breakdown(offPeakKWh: offKWh, peakKWh: peakKWh, cost: cost, blendedRate: cost / kWh)
        }
    }

    /// One-line description for lists and pickers.
    var summary: String {
        switch kind {
        case .fixed:
            return "Fixed \(RatePlan.priceText(fixedRate))/kWh"
        case .timeOfUse:
            return "Off-peak \(RatePlan.priceText(offPeakRate)) • Peak \(RatePlan.priceText(peakRate))/kWh"
        }
    }

    static func priceText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2...3)))
    }

    static func timeText(minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Storage

/// Persists the plans as JSON in UserDefaults. Views read it through
/// `@AppStorage(RatePlanStore.key)` so a change made in Settings shows up in an
/// open charge form straight away.
enum RatePlanStore {
    static let key = "homeChargingRatePlans"

    static func decode(_ data: Data) -> [RatePlan] {
        (try? JSONDecoder().decode([RatePlan].self, from: data)) ?? []
    }

    static func encode(_ plans: [RatePlan]) -> Data {
        (try? JSONEncoder().encode(plans)) ?? Data()
    }

    static func load() -> [RatePlan] {
        decode(UserDefaults.standard.data(forKey: key) ?? Data())
    }

    static func save(_ plans: [RatePlan]) {
        UserDefaults.standard.set(encode(plans), forKey: key)
    }
}

// MARK: - Management screen

/// Settings > Charging Rates: the list of the household's electricity plans.
struct RatePlansView: View {
    @AppStorage(RatePlanStore.key) private var storedData: Data = Data()
    @State private var editing: RatePlan?

    private var plans: [RatePlan] { RatePlanStore.decode(storedData) }

    var body: some View {
        List {
            Section {
                if plans.isEmpty {
                    Text("No rate plans yet. Add your home electricity rate and charges logged at home will be priced from it automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(plans) { plan in
                    Button { editing = plan } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.name).font(.headline).foregroundStyle(.primary)
                            Text(plan.summary).font(.subheadline).foregroundStyle(.secondary)
                            if plan.kind == .timeOfUse {
                                Text("Off-peak \(RatePlan.timeText(minute: plan.offPeakStartMinute)) – \(RatePlan.timeText(minute: plan.offPeakEndMinute))\(plan.weekendsAllOffPeak ? " and weekends" : "")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    var updated = plans
                    updated.remove(atOffsets: offsets)
                    storedData = RatePlanStore.encode(updated)
                }
            } footer: {
                Text("Plans are saved on this device. Charges already logged keep the price they were saved with if a plan changes later.")
            }
        }
        .navigationTitle("Home Charging Rates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = RatePlan(name: "Home") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Rate Plan")
            }
        }
        .sheet(item: $editing) { plan in
            NavigationStack {
                RatePlanEditor(plan: plan) { saved in
                    var updated = plans
                    if let index = updated.firstIndex(where: { $0.id == saved.id }) { updated[index] = saved } else { updated.append(saved) }
                    storedData = RatePlanStore.encode(updated)
                }
            }
        }
    }
}

/// Add or edit one plan.
private struct RatePlanEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RatePlan
    @State private var fixedText: String
    @State private var peakText: String
    @State private var offPeakText: String
    let onSave: (RatePlan) -> Void

    init(plan: RatePlan, onSave: @escaping (RatePlan) -> Void) {
        _draft = State(initialValue: plan)
        _fixedText = State(initialValue: plan.fixedRate > 0 ? String(plan.fixedRate) : "")
        _peakText = State(initialValue: plan.peakRate > 0 ? String(plan.peakRate) : "")
        _offPeakText = State(initialValue: plan.offPeakRate > 0 ? String(plan.offPeakRate) : "")
        self.onSave = onSave
    }

    private func number(_ text: String) -> Double {
        max(0, Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    private func date(forMinute minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch draft.kind {
        case .fixed: return number(fixedText) > 0
        case .timeOfUse: return number(peakText) > 0 || number(offPeakText) > 0
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $draft.kind) {
                    ForEach(RatePlan.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch draft.kind {
            case .fixed:
                Section("Price") {
                    FormTextField(title: "Price per kWh", placeholder: "e.g., 0.16", text: $fixedText, keyboardType: .decimalPad)
                }
            case .timeOfUse:
                Section("Prices") {
                    FormTextField(title: "Off-peak per kWh", placeholder: "e.g., 0.12", text: $offPeakText, keyboardType: .decimalPad)
                    FormTextField(title: "Peak per kWh", placeholder: "e.g., 0.34", text: $peakText, keyboardType: .decimalPad)
                }
                Section {
                    DatePicker("Off-peak starts", selection: Binding(get: { date(forMinute: draft.offPeakStartMinute) }, set: { draft.offPeakStartMinute = minute(of: $0) }), displayedComponents: .hourAndMinute)
                    DatePicker("Off-peak ends", selection: Binding(get: { date(forMinute: draft.offPeakEndMinute) }, set: { draft.offPeakEndMinute = minute(of: $0) }), displayedComponents: .hourAndMinute)
                    Toggle("Weekends all off-peak", isOn: $draft.weekendsAllOffPeak)
                } header: {
                    Text("Off-Peak Hours")
                } footer: {
                    Text("Any other time is billed at the peak price. A window can run past midnight, such as 9:00 PM to 6:00 AM.")
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Rate Plan" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.fixedRate = number(fixedText)
                    saved.peakRate = number(peakText)
                    saved.offPeakRate = number(offPeakText)
                    onSave(saved)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
