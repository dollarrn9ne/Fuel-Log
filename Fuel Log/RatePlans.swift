import SwiftUI
import SwiftData
import FuelLogShared

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
    /// When this plan was last edited, so the newest edit wins when two devices
    /// disagree. Optional so plans saved before sync existed still decode.
    var modifiedAt: Date?
    /// The months (1-12) this plan applies, for a seasonal rate such as summer
    /// and winter prices. Both nil means year-round. The range may wrap the new
    /// year (November through March). Optional, not defaulted: a missing key
    /// fails to decode, and plans saved before seasons existed have none.
    var seasonStartMonth: Int?
    var seasonEndMonth: Int?

    /// One step of a tiered plan: energy up to `upToKWh` this month costs `rate`.
    /// The last tier has no limit and covers everything above.
    struct Tier: Codable, Equatable, Identifiable {
        var id = UUID()
        var upToKWh: Double?
        var rate: Double
    }

    /// A tiered plan (price rises with the month's household use) is stored as a
    /// fixed plan with tiers, not a new `Kind`: a build that doesn't know a new
    /// kind fails to decode the whole plan list, and would then overwrite iCloud
    /// with an empty one. `fixedRate` holds the first tier's price so an older
    /// build still prices a tiered plan sensibly. Optional for the same reason
    /// as the season fields.
    var tiers: [Tier]?
    /// What the rest of the household uses in a month before any EV charging,
    /// since the app can't see the meter. Counts toward which tier a charge is in.
    var tierBaselineKWh: Double?
    /// Vehicles (by id string) this plan is the default for, so a charge on one
    /// of them picks it without asking. Kept on the plan, not on `Vehicle`, so
    /// it syncs with the plan and needs no new synced field.
    var defaultVehicleIDs: [String]?

    var isTiered: Bool { kind == .fixed && !(tiers ?? []).isEmpty }

    func isDefault(for vehicleID: UUID) -> Bool {
        (defaultVehicleIDs ?? []).contains(vehicleID.uuidString)
    }

    /// The result of pricing one session against a plan.
    struct Breakdown: Equatable {
        var offPeakKWh: Double
        var peakKWh: Double
        var cost: Double
        var blendedRate: Double
        /// For a tiered plan, how the session's kWh fell across the tiers.
        var tierSlices: [TierSlice] = []
    }

    struct TierSlice: Equatable {
        var kWh: Double
        var rate: Double
    }

    /// Splits `kWh` across the tiers, given how much the household had already
    /// used this month. Only the part of the session above each tier's start
    /// and below its limit lands in it.
    func tierSlices(kWh: Double, usedBefore: Double) -> [TierSlice] {
        let used = max(0, usedBefore)
        var lower = 0.0
        var slices: [TierSlice] = []
        for tier in tiers ?? [] {
            let upper = tier.upToKWh ?? .infinity
            let inTier = max(0, min(used + kWh, upper) - max(used, lower))
            slices.append(TierSlice(kWh: inTier, rate: tier.rate))
            lower = upper
        }
        return slices
    }

    var hasSeason: Bool { seasonStartMonth != nil && seasonEndMonth != nil }

    /// Whether the plan applies in the month of `date`. Year-round plans always do.
    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let start = seasonStartMonth, let end = seasonEndMonth else { return true }
        let month = calendar.component(.month, from: date)
        if start <= end { return month >= start && month <= end }
        return month >= start || month <= end   // wraps the new year
    }

    /// "Jun – Sep" for a seasonal plan, nil for a year-round one.
    var seasonText: String? {
        guard let start = seasonStartMonth, let end = seasonEndMonth,
              (1...12).contains(start), (1...12).contains(end) else { return nil }
        let names = Calendar.current.shortMonthSymbols
        return start == end ? names[start - 1] : "\(names[start - 1]) – \(names[end - 1])"
    }

    /// The plan a charge on `date` should use without being asked, or nil when
    /// there isn't a single clear one. The vehicle's own default plan comes
    /// first, then a plan for the current season beats a year-round one; two
    /// equally good candidates are left for the user to pick.
    static func bestMatch(in plans: [RatePlan], on date: Date, vehicleID: UUID? = nil, calendar: Calendar = .current) -> RatePlan? {
        var active = plans.filter { $0.isActive(on: date, calendar: calendar) }
        // Plans marked as this vehicle's default come first; if none apply on
        // this date (say, a winter-only default in July) fall back to the rest.
        if let vehicleID {
            let defaults = active.filter { $0.isDefault(for: vehicleID) }
            if !defaults.isEmpty { active = defaults }
        }
        let seasonal = active.filter(\.hasSeason)
        let pool = seasonal.isEmpty ? active : seasonal
        return pool.count == 1 ? pool[0] : nil
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
    func breakdown(kWh: Double, start: Date, minutes: Int?, householdKWhBefore: Double = 0, calendar: Calendar = .current) -> Breakdown {
        guard kWh > 0 else { return Breakdown(offPeakKWh: 0, peakKWh: 0, cost: 0, blendedRate: 0) }
        switch kind {
        case .fixed where isTiered:
            let slices = tierSlices(kWh: kWh, usedBefore: householdKWhBefore)
            let cost = slices.reduce(0) { $0 + $1.kWh * $1.rate }
            return Breakdown(offPeakKWh: 0, peakKWh: kWh, cost: cost, blendedRate: cost / kWh, tierSlices: slices)
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
        case .fixed where isTiered:
            let rates = (tiers ?? []).map(\.rate)
            return "Tiered \(RatePlan.priceText(rates.min() ?? 0)) – \(RatePlan.priceText(rates.max() ?? 0))/kWh"
        case .fixed:
            return "Fixed \(RatePlan.priceText(fixedRate))/kWh"
        case .timeOfUse:
            return "Off-peak \(RatePlan.priceText(offPeakRate)) • Peak \(RatePlan.priceText(peakRate))/kWh"
        }
    }

    /// "First 300 kWh 0.12 • next 500 kWh 0.18 • above 0.30" for a tiered plan.
    var tierDescription: String {
        var lower = 0.0
        var parts: [String] = []
        for tier in tiers ?? [] {
            if let limit = tier.upToKWh {
                let size = limit - lower
                parts.append("\(parts.isEmpty ? "first" : "next") \(Int(size.rounded())) kWh \(RatePlan.priceText(tier.rate))")
                lower = limit
            } else {
                parts.append("above \(RatePlan.priceText(tier.rate))")
            }
        }
        return parts.joined(separator: " • ")
    }

    static func priceText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2...3)))
    }

    static func timeText(minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Storage and sync

/// Where the plans live. The local copy is JSON in UserDefaults, which is what
/// views read through `@AppStorage(RatePlanStore.key)`, so a change shows up in
/// an open charge form straight away. It's mirrored to iCloud's key-value store
/// so the same plans appear on every device signed into the account.
///
/// The key-value store is used instead of a new synced database model on
/// purpose: the app already holds the key-value entitlement (so no capability or
/// signing change), and a new model type would put the CloudKit schema and the
/// container's wipe-and-retry fallback at risk for what is a handful of numbers.
///
/// Devices merge per plan: the most recently edited copy wins, a deleted plan is
/// remembered so it doesn't reappear from a device that hasn't heard yet, and
/// identical plans created separately on two devices collapse into one. Charges
/// keep only the plan's *name* and the blended price, so none of that touches
/// logged data.
enum RatePlanStore {
    static let key = "homeChargingRatePlans"
    private static let tombstoneKey = "homeChargingRatePlanTombstones"
    private static let cloudKey = "homeChargingRatePlans.sync"

    /// Everything that travels between devices.
    struct SyncEnvelope: Codable, Equatable {
        var plans: [RatePlan]
        /// Plan id -> when it was deleted.
        var deleted: [String: Date]
    }

    static func decode(_ data: Data) -> [RatePlan] {
        (try? JSONDecoder().decode([RatePlan].self, from: data)) ?? []
    }

    static func encode(_ plans: [RatePlan]) -> Data {
        (try? JSONEncoder().encode(plans)) ?? Data()
    }

    static func load() -> [RatePlan] {
        decode(UserDefaults.standard.data(forKey: key) ?? Data())
    }

    private static func loadTombstones() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: tombstoneKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private static var localEnvelope: SyncEnvelope {
        SyncEnvelope(plans: load(), deleted: loadTombstones())
    }

    // MARK: Local edits

    /// Adds or replaces a plan, stamping it as just edited.
    static func upsert(_ plan: RatePlan) {
        var edited = plan
        edited.modifiedAt = Date()
        var envelope = localEnvelope
        if let index = envelope.plans.firstIndex(where: { $0.id == edited.id }) { envelope.plans[index] = edited } else { envelope.plans.append(edited) }
        envelope.deleted[edited.id.uuidString] = nil
        write(envelope)
    }

    static func delete(ids: Set<UUID>) {
        var envelope = localEnvelope
        envelope.plans.removeAll { ids.contains($0.id) }
        for id in ids { envelope.deleted[id.uuidString] = Date() }
        write(envelope)
    }

    /// Replaces every plan, as a backup restore does.
    static func replaceAll(_ plans: [RatePlan]) {
        var envelope = localEnvelope
        let incoming = Set(plans.map(\.id))
        for existing in envelope.plans where !incoming.contains(existing.id) { envelope.deleted[existing.id.uuidString] = Date() }
        envelope.plans = plans.map { var plan = $0; plan.modifiedAt = Date(); return plan }
        for plan in plans { envelope.deleted[plan.id.uuidString] = nil }
        write(envelope)
    }

    /// Saves locally and pushes to iCloud.
    private static func write(_ envelope: SyncEnvelope) {
        writeLocal(envelope)
        pushToCloud(envelope)
    }

    private static func writeLocal(_ envelope: SyncEnvelope) {
        let sorted = envelope.plans.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        UserDefaults.standard.set(encode(sorted), forKey: key)
        UserDefaults.standard.set(try? JSONEncoder().encode(envelope.deleted), forKey: tombstoneKey)
    }

    // MARK: iCloud

    private static func pushToCloud(_ envelope: SyncEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: cloudKey)
        store.synchronize()
    }

    /// Merges whatever iCloud holds into the local copy, and pushes back anything
    /// iCloud is missing. Safe to call at any time and as often as needed.
    static func pullFromCloud() {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        let local = localEnvelope
        guard let data = store.data(forKey: cloudKey),
              let remote = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else {
            // Nothing in iCloud yet: publish what this device has.
            if !local.plans.isEmpty || !local.deleted.isEmpty { pushToCloud(local) }
            return
        }
        let merged = merge(local, remote)
        if merged != local { writeLocal(merged) }
        if merged != remote { pushToCloud(merged) }
    }

    /// Re-merges whenever another device changes the store. Run for the life of
    /// the app, e.g. from a `.task`.
    static func keepInSyncWithICloud() async {
        pullFromCloud()
        for await _ in NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification) {
            pullFromCloud()
        }
    }

    // MARK: Merge

    /// Combines two devices' views of the plans. Pure, so it can be checked on its
    /// own with fixed inputs.
    static func merge(_ a: SyncEnvelope, _ b: SyncEnvelope) -> SyncEnvelope {
        var deleted = a.deleted.merging(b.deleted) { max($0, $1) }

        // Newest edit wins for a plan present on both sides.
        var byID: [UUID: RatePlan] = [:]
        for plan in a.plans + b.plans {
            if let existing = byID[plan.id], (existing.modifiedAt ?? .distantPast) >= (plan.modifiedAt ?? .distantPast) { continue }
            byID[plan.id] = plan
        }

        // A deletion beats a plan that hasn't been edited since.
        for (idString, when) in deleted {
            guard let id = UUID(uuidString: idString), let plan = byID[id] else { continue }
            if when >= (plan.modifiedAt ?? .distantPast) { byID[id] = nil }
        }

        // The same plan entered by hand on two devices has two ids; keep one (the
        // lowest id, so every device picks the same) and delete the other.
        var keptForContent: [String: RatePlan] = [:]
        for plan in byID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let signature = plan.contentSignature
            if keptForContent[signature] == nil {
                keptForContent[signature] = plan
            } else {
                byID[plan.id] = nil
                deleted[plan.id.uuidString] = Date()
            }
        }

        let plans = byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        return SyncEnvelope(plans: plans, deleted: deleted)
    }
}

extension RatePlan {
    /// Two plans with the same signature price every session identically.
    var contentSignature: String {
        "\(name.lowercased())|\(kind.rawValue)|\(fixedRate)|\(peakRate)|\(offPeakRate)|\(offPeakStartMinute)|\(offPeakEndMinute)|\(weekendsAllOffPeak)|\(seasonStartMonth ?? 0)|\(seasonEndMonth ?? 0)|\((tiers ?? []).map { "\($0.upToKWh ?? -1):\($0.rate)" }.joined(separator: ","))|\(tierBaselineKWh ?? 0)"
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
                            if plan.isTiered {
                                Text(plan.tierDescription)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let season = plan.seasonText {
                                Text("Applies \(season)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if plan.kind == .timeOfUse {
                                Text("Off-peak \(RatePlan.timeText(minute: plan.offPeakStartMinute)) – \(RatePlan.timeText(minute: plan.offPeakEndMinute))\(plan.weekendsAllOffPeak ? " and weekends" : "")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    RatePlanStore.delete(ids: Set(offsets.map { plans[$0].id }))
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
                    RatePlanStore.upsert(saved)
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
    @State private var style: Style
    @State private var tierRows: [TierRow]
    @State private var baselineText: String
    @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
    let onSave: (RatePlan) -> Void

    /// How the plan charges. Tiered is a fixed plan with tiers underneath (see
    /// `RatePlan.tiers`), so this is an editing choice, not a stored kind.
    private enum Style: String, CaseIterable, Identifiable {
        case fixed = "Fixed"
        case timeOfUse = "Time of Use"
        case tiered = "Tiered"
        var id: String { rawValue }
    }

    private struct TierRow: Identifiable {
        var id = UUID()
        var limit: String
        var rate: String
    }

    init(plan: RatePlan, onSave: @escaping (RatePlan) -> Void) {
        _style = State(initialValue: plan.isTiered ? .tiered : (plan.kind == .timeOfUse ? .timeOfUse : .fixed))
        _tierRows = State(initialValue: (plan.tiers ?? []).isEmpty
            ? [TierRow(limit: "", rate: "")]
            : (plan.tiers ?? []).map { TierRow(limit: $0.upToKWh.map { String($0) } ?? "", rate: String($0.rate)) })
        _baselineText = State(initialValue: (plan.tierBaselineKWh ?? 0) > 0 ? String(plan.tierBaselineKWh ?? 0) : "")
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

    /// Every tier needs a price; every tier but the last needs a limit, and the
    /// limits must climb.
    private var tiersValid: Bool {
        guard !tierRows.isEmpty else { return false }
        var previous = 0.0
        for (index, row) in tierRows.enumerated() {
            guard number(row.rate) > 0 else { return false }
            if index < tierRows.count - 1 {
                let limit = number(row.limit)
                guard limit > previous else { return false }
                previous = limit
            }
        }
        return true
    }

    private var builtTiers: [RatePlan.Tier] {
        tierRows.enumerated().map { index, row in
            RatePlan.Tier(upToKWh: index == tierRows.count - 1 ? nil : number(row.limit), rate: number(row.rate))
        }
    }

    /// Electric and plug-in hybrid vehicles that could be given a default plan.
    private var chargeableVehicles: [Vehicle] {
        vehicles.filter { !$0.isArchived && ($0.fuelType == .electric || $0.fuelType == .plugInHybrid) }
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch draft.kind {
        case .fixed: return style == .tiered ? tiersValid : number(fixedText) > 0
        case .timeOfUse: return number(peakText) > 0 || number(offPeakText) > 0
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Picker("Type", selection: $style) {
                    ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: style) { _, newStyle in
                    draft.kind = newStyle == .timeOfUse ? .timeOfUse : .fixed
                }
            }

            switch draft.kind {
            case .fixed where style == .tiered:
                Section {
                    ForEach($tierRows) { $row in
                        HStack {
                            if row.id == tierRows.last?.id {
                                Text(tierRows.count == 1 ? "All usage" : "Above")
                                Spacer()
                            } else {
                                Text("Up to")
                                TextField("kWh", text: $row.limit)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("kWh")
                            }
                            Text("@").foregroundStyle(.secondary)
                            TextField("0.00", text: $row.rate)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                        }
                    }
                    .onDelete { offsets in
                        guard tierRows.count > offsets.count else { return }
                        tierRows.remove(atOffsets: offsets)
                    }
                    Button("Add Tier") { tierRows.append(TierRow(limit: "", rate: "")) }
                } header: {
                    Text("Tiers (per month)")
                } footer: {
                    Text("The price per kWh rises as the household's monthly use passes each limit. The last tier covers everything above. Swipe a tier to remove it.")
                }
                Section {
                    FormTextField(title: "Other household use (kWh/month)", placeholder: "e.g., 600", text: $baselineText, keyboardType: .decimalPad)
                } footer: {
                    Text("What the home uses each month apart from charging. A charge is priced by where the month's total lands: this plus home charges already logged that calendar month.")
                }
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

            if !chargeableVehicles.isEmpty {
                Section {
                    ForEach(chargeableVehicles) { vehicle in
                        Toggle(vehicle.name, isOn: Binding(
                            get: { draft.isDefault(for: vehicle.id) },
                            set: { on in
                                var ids = Set(draft.defaultVehicleIDs ?? [])
                                if on { ids.insert(vehicle.id.uuidString) } else { ids.remove(vehicle.id.uuidString) }
                                draft.defaultVehicleIDs = ids.isEmpty ? nil : ids.sorted()
                            }
                        ))
                    }
                } header: {
                    Text("Default For")
                } footer: {
                    Text("Home charges on these vehicles use this plan automatically.")
                }
            }

            Section {
                Toggle("Only part of the year", isOn: Binding(
                    get: { draft.hasSeason },
                    set: { on in
                        draft.seasonStartMonth = on ? 6 : nil
                        draft.seasonEndMonth = on ? 9 : nil
                    }
                ))
                if draft.hasSeason {
                    Picker("From", selection: Binding(get: { draft.seasonStartMonth ?? 6 }, set: { draft.seasonStartMonth = $0 })) {
                        ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                    }
                    Picker("Through", selection: Binding(get: { draft.seasonEndMonth ?? 9 }, set: { draft.seasonEndMonth = $0 })) {
                        ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                    }
                }
            } header: {
                Text("Season")
            } footer: {
                Text(draft.hasSeason
                     ? "Charges logged in these months use this plan automatically. Add another plan for the rest of the year, such as a winter rate. Whole months only."
                     : "Turn on if the rate changes with the season, such as summer and winter prices.")
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
                    if style == .tiered {
                        saved.tiers = builtTiers
                        saved.tierBaselineKWh = number(baselineText) > 0 ? number(baselineText) : nil
                        // An older build ignores tiers, so give it the first tier's price.
                        saved.fixedRate = saved.tiers?.first?.rate ?? 0
                    } else {
                        saved.tiers = nil
                        saved.tierBaselineKWh = nil
                    }
                    onSave(saved)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
