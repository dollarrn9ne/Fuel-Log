import SwiftUI
import Charts
import FuelLogShared

struct VehicleChartsView: View {
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    
    @State private var timeframe: ChartTimeframe = .sixMonths
    @State private var scrollPosition: Date = Date()
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()
    
    enum ChartTimeframe: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case sixMonths = "6M"
        case year = "1Y"
        case twoYears = "2Y"
        case all = "All"
        case custom = "Custom"
        var id: String { rawValue }
    }
    
    var filteredFills: [FillUp] {
        let sorted = (vehicle.fillUps ?? []).sorted { $0.date < $1.date }
        let now = Date()
        let cal = Calendar.current
        switch timeframe {
        case .oneMonth:
            guard let d = cal.date(byAdding: .month, value: -1, to: now) else { return sorted }
            return sorted.filter { $0.date >= d }
        case .sixMonths:
            guard let d = cal.date(byAdding: .month, value: -6, to: now) else { return sorted }
            return sorted.filter { $0.date >= d }
        case .year:
            guard let d = cal.date(byAdding: .year, value: -1, to: now) else { return sorted }
            return sorted.filter { $0.date >= d }
        case .twoYears:
            guard let d = cal.date(byAdding: .year, value: -2, to: now) else { return sorted }
            return sorted.filter { $0.date >= d }
        case .all:
            return sorted
        case .custom:
            return sorted.filter { $0.date >= customStart && $0.date <= customEnd }
        }
    }
    
    var efficiencyData: [(date: Date, value: Double)] {
        let allSorted = (vehicle.fillUps ?? []).sorted { $0.date < $1.date }
        let electricEfficiency = vehicle.efficiencyUnit == .miPerKWh || vehicle.efficiencyUnit == .kmPerKWh
        var effDict: [UUID: Double] = [:]
        
        for (prev, curr) in zip(allSorted, allSorted.dropFirst()) {
            guard let cOdo = curr.odometer, let pOdo = prev.odometer, cOdo > pOdo, curr.isFullTank else { continue }
            if (curr.unit == .kwh) != electricEfficiency { continue }
            let dist = cOdo - pOdo
            let vol = curr.volume
            if vol > 0 && dist > 0 {
                let val = EfficiencyConverter.convert(distance: dist, odometerUnit: vehicle.odometerUnit, volume: vol, fuelUnit: vehicle.fuelUnit, to: vehicle.efficiencyUnit)
                effDict[curr.id] = val
            }
        }
        
        return filteredFills.compactMap { f in
            if let val = effDict[f.id] {
                return (f.date, val)
            }
            return nil
        }
    }
    
    var totalCost: Double { filteredFills.reduce(0) { $0 + $1.totalCost } }
    var totalVolume: Double { filteredFills.reduce(0) { $0 + $1.volume } }
    var totalDistance: Double {
        let odos = filteredFills.compactMap(\.odometer)
        guard let minOdo = odos.min(), let maxOdo = odos.max(), maxOdo > minOdo else { return 0 }
        return maxOdo - minOdo
    }
    var avgPrice: Double { totalVolume > 0 ? totalCost / totalVolume : 0 }
    var avgEff: Double? {
        // Accumulate full-tank segments (rolling partial fills into the next full
        // tank) so this matches Vehicle.averageEfficiency / the dashboard value.
        // The earliest fill only "opens" a window; its fuel isn't attributed to
        // any measured distance, which is why a plain (maxOdo-minOdo)/totalVolume
        // under-reports economy.
        let sorted = filteredFills.sorted { $0.date < $1.date }
        let electricEfficiency = vehicle.efficiencyUnit == .miPerKWh || vehicle.efficiencyUnit == .kmPerKWh
        var dist: Double = 0, vol: Double = 0
        var lastFullOdo: Double? = nil
        var volumeSinceLastFull: Double = 0
        for fill in sorted {
            if (fill.unit == .kwh) != electricEfficiency { continue }
            guard let odo = fill.odometer else { continue }
            volumeSinceLastFull += fill.volume
            if fill.isFullTank {
                if let prevOdo = lastFullOdo, odo > prevOdo {
                    dist += (odo - prevOdo)
                    vol += volumeSinceLastFull
                }
                lastFullOdo = odo
                volumeSinceLastFull = 0
            }
        }
        guard vol > 0, dist > 0 else { return nil }
        return EfficiencyConverter.convert(distance: dist, odometerUnit: vehicle.odometerUnit, volume: vol, fuelUnit: vehicle.fuelUnit, to: vehicle.efficiencyUnit)
    }
    var days: Double {
        guard let first = filteredFills.first?.date, let last = filteredFills.last?.date, last > first else { return 1 }
        return max(1, last.timeIntervalSince(first) / 86400)
    }
    var costPerDay: Double { totalCost / days }
    var distPerDay: Double { totalDistance / days }
    
    var visibleDomain: TimeInterval {
        switch timeframe {
        case .oneMonth: return 3600 * 24 * 30
        case .sixMonths: return 3600 * 24 * 180
        case .year: return 3600 * 24 * 180 // When viewing large timespans, scroll chunks
        case .twoYears: return 3600 * 24 * 365
        case .all: return 3600 * 24 * 365
        case .custom: return max(3600 * 24, customEnd.timeIntervalSince(customStart))
        }
    }

    /// The visible window actually applied to the chart. When the data spans less
    /// than `visibleDomain` (the common case), we shrink the window to the data
    /// span so the points fill the width instead of clustering into a thin sliver
    /// on the left. When the data spans more, we keep the timeframe window and let
    /// the chart scroll.
    var effectiveVisibleDomain: TimeInterval {
        guard let first = filteredFills.first?.date, let last = filteredFills.last?.date, last > first else {
            return visibleDomain
        }
        let span = last.timeIntervalSince(first)
        let paddedSpan = span * 1.15 // a little breathing room on each edge
        return min(visibleDomain, max(paddedSpan, 3600 * 24))
    }

    /// Anchors the scroll so the most recent fill-ups are visible. If the whole
    /// data set fits in the window, this lands on the first fill (showing all).
    private func resetScrollPosition() {
        guard let first = filteredFills.first?.date, let last = filteredFills.last?.date else { return }
        let leading = max(first.timeIntervalSince1970, last.timeIntervalSince1970 - effectiveVisibleDomain)
        scrollPosition = Date(timeIntervalSince1970: leading)
    }
    
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        Picker("Timeframe", selection: $timeframe) {
                            ForEach(ChartTimeframe.allCases) { tf in
                                Text(tf.rawValue).tag(tf)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        if timeframe == .custom {
                            VStack(alignment: .leading, spacing: 12) {
                                DatePicker("From", selection: $customStart, displayedComponents: .date)
                                DatePicker("To", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                            }
                            .padding(.horizontal)
                            .onChange(of: customStart) { _, newStart in
                                if customEnd < newStart { customEnd = newStart }
                            }
                        }

                        if filteredFills.count > 1 {
                            // iPad's own branch, kept separate from iPhone's below so a
                            // change made for one screen size can't reach the other.
                            if isWideLayout(proxy) {
                                if isPortrait(proxy) {
                                    // Portrait: chart on top, details below. The side by
                                    // side split (still used in landscape, right below)
                                    // read here as the chart and the stats competing for
                                    // the same cramped column instead of each getting the
                                    // width it needed.
                                    VStack(spacing: 16) {
                                        chartsCard(priceHeight: 200, efficiencyHeight: 280)
                                        heroEfficiencyCard
                                        statsTileGrid(columns: 3)
                                        gradeComparisonCard
                                    }
                                    .padding(.horizontal)
                                } else {
                                    // Landscape: unchanged - the chart and a column of
                                    // stats beside it, which the width here suits fine.
                                    let heights = landscapeChartHeights(for: proxy)
                                    HStack(alignment: .top, spacing: 20) {
                                        chartsCard(priceHeight: heights.price, efficiencyHeight: heights.efficiency)
                                        VStack(spacing: 16) {
                                            heroEfficiencyCard
                                            statsTileGrid(columns: 2)
                                            gradeComparisonCard
                                        }
                                        .frame(width: 380)
                                    }
                                    .padding(.horizontal)
                                }
                            } else {
                                VStack(spacing: 16) {
                                    chartsCard(priceHeight: 120, efficiencyHeight: 160)
                                    heroEfficiencyCard
                                    statsTileGrid(columns: 2)
                                    gradeComparisonCard
                                }
                                .padding(.horizontal)
                            }
                        } else {
                            ContentUnavailableView("Not Enough Data", systemImage: "chart.xyaxis.line", description: Text("Log at least two fill-ups in this timeframe to see your charts."))
                        }
                    }
                    .padding(.vertical)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Trends & Charts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { resetScrollPosition() }
            .onChange(of: timeframe) { _, _ in resetScrollPosition() }
            .onChange(of: customStart) { _, _ in resetScrollPosition() }
            .onChange(of: customEnd) { _, _ in resetScrollPosition() }
        }
    }

    /// Wide enough on an iPad to earn taller charts and a third grid column.
    /// Excluded on iPhone even in landscape, where those would stretch the
    /// same handful of tiles thinner rather than looking more considered.
    private func isWideLayout(_ proxy: GeometryProxy) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && proxy.size.width > 700
    }

    private func isPortrait(_ proxy: GeometryProxy) -> Bool {
        proxy.size.height >= proxy.size.width
    }

    /// Landscape keeps the side-by-side split, and the chart's height is sized
    /// off the window the way it originally was there: proportional to the
    /// leftover height, floored and capped rather than the portrait branch's
    /// fixed numbers.
    private func landscapeChartHeights(for proxy: GeometryProxy) -> (price: CGFloat, efficiency: CGFloat) {
        let available = proxy.size.height - 100
        let price = min(max(available * 0.24, 200), 320)
        let efficiency = min(max(available * 0.34, 260), 460)
        return (price, efficiency)
    }

    @ViewBuilder
    private func chartsCard(priceHeight: CGFloat, efficiencyHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Price Chart
            syncableChart(
                Chart(filteredFills) { fillUp in
                    LineMark(
                        x: .value("Date", fillUp.date),
                        y: .value("Price", fillUp.pricePerUnit)
                    )
                    .foregroundStyle(Color.yellow)
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("Date", fillUp.date),
                        y: .value("Price", fillUp.pricePerUnit)
                    )
                    .foregroundStyle(Color.yellow)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisTick()
                        if let val = value.as(Double.self) {
                            AxisValueLabel(val.formatted(.currency(code: vehicle.currencyRaw)))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 1)) { _ in
                        AxisGridLine()
                    }
                }
                .frame(height: priceHeight)
                .overlay(alignment: .topLeading) {
                    Text("\(vehicle.currencyRaw)/\(vehicle.fuelUnit.rawValue.prefix(3).lowercased())")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.yellow)
                        .padding([.top, .leading], 8)
                }
            )

            // Vertical breathing room, not just the hairline itself: Swift
            // Charts can let a y-axis tick label (e.g. the price chart's
            // "$0.00") spill slightly past its chart's own frame, which with
            // no gap here collided with the efficiency chart's "MPG (US)"
            // caption directly beneath it.
            Divider().background(Color.white.opacity(0.1)).padding(.vertical, 8)

            // Efficiency Chart
            syncableChart(
                Chart(efficiencyData, id: \.date) { item in
                    LineMark(
                        x: .value("Date", item.date),
                        y: .value("Efficiency", item.value)
                    )
                    .foregroundStyle(Color.pink)
                    .interpolationMethod(.stepCenter)

                    AreaMark(
                        x: .value("Date", item.date),
                        y: .value("Efficiency", item.value)
                    )
                    .foregroundStyle(LinearGradient(colors: [Color.pink.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.stepCenter)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 1)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                    }
                }
                .frame(height: efficiencyHeight)
                .overlay(alignment: .topLeading) {
                    Text(vehicle.efficiencyUnit.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.pink)
                        .padding([.top, .leading], 8)
                }
            )
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The headline efficiency number, in its own card rather than stacked
    /// above the other figures - it's the one stat worth reading at a glance
    /// from across the room. Shared by iPhone and iPad.
    @ViewBuilder
    private var heroEfficiencyCard: some View {
        if let eff = avgEff {
            HStack(spacing: 16) {
                Image(systemName: vehicle.fuelType == .electric ? "bolt.car.fill" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.2f", eff))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(vehicle.efficiencyUnit.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Each stat in its own tile with a coloured icon, shared by iPhone and
    /// iPad; two dense columns of plain text (the original phone card) didn't
    /// hold its own under a full-width chart. Three columns once there's the
    /// width to spare, so the tiles stay roughly card-shaped instead of
    /// stretching into wide, mostly-empty bars.
    private func statsTileGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            StatTile(icon: "dollarsign.circle.fill", tint: .green,
                      value: totalCost.formatted(.currency(code: vehicle.currencyRaw)),
                      label: vehicle.fuelType == .electric ? "Total Energy Cost" : "Total Fuel Cost")
            StatTile(icon: vehicle.fuelType == .electric ? "bolt.fill" : "fuelpump.fill", tint: .blue,
                      value: "\(Int(totalVolume)) \(vehicle.fuelUnit.rawValue.lowercased())",
                      label: "Total Volume")
            StatTile(icon: "tag.fill", tint: .orange,
                      value: avgPrice.formatted(.currency(code: vehicle.currencyRaw)) + "/\(vehicle.fuelUnit.rawValue.prefix(3).lowercased())",
                      label: "Avg Price")
            StatTile(icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .purple,
                      value: "\(Int(totalDistance).formatted()) \(vehicle.odometerUnit.rawValue.lowercased())",
                      label: "Total Distance")
            StatTile(icon: "calendar", tint: .teal,
                      value: String(format: "%.1f", distPerDay) + " \(vehicle.odometerUnit.rawValue.prefix(2).lowercased())/day",
                      label: "Distance / Day")
            StatTile(icon: "creditcard.fill", tint: .pink,
                      value: costPerDay.formatted(.currency(code: vehicle.currencyRaw)) + "/day",
                      label: "Cost / Day")
        }
    }

    /// Compares efficiency across the fuel grades this vehicle has actually used
    /// (e.g. E85 vs Regular). Only shown when more than one grade is recorded,
    /// since that's the case where a single blended average is misleading.
    ///
    /// Cost per distance is the figure that actually settles whether a cheaper
    /// but less efficient fuel is worth it.
    @ViewBuilder private var gradeComparisonCard: some View {
        let comparison = vehicle.efficiencyByGrade
        if comparison.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Text("BY FUEL GRADE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                ForEach(comparison, id: \.name) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.name)
                            .font(.subheadline.weight(.bold))
                            .frame(minWidth: 70, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(format: "%.1f", entry.efficiency)) \(vehicle.efficiencyUnit.rawValue)")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                            if let costPer = costPerDistance(for: entry) {
                                Text(costPer)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                    }
                }

                Text("Efficiency is measured only from tanks filled with a single grade, so mixed tanks are excluded.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Average fuel cost per unit of distance for a grade, e.g. "$0.15/mi".
    private func costPerDistance(for entry: (name: String, efficiency: Double)) -> String? {
        guard let price = vehicle.averagePrice(forGradeNamed: entry.name), price > 0, entry.efficiency > 0 else { return nil }
        // For L/100 km, efficiency is consumption (volume per distance) rather
        // than distance per volume, so the cost math inverts.
        let perDistance: Double
        switch vehicle.efficiencyUnit {
        case .l100km:
            perDistance = price * entry.efficiency / 100
        default:
            perDistance = price / entry.efficiency
        }
        let distanceSuffix = vehicle.odometerUnit == .miles ? "mi" : "km"
        return perDistance.formatted(.currency(code: vehicle.currencyRaw).precision(.fractionLength(3))) + "/\(distanceSuffix)"
    }

    @ViewBuilder
    private func syncableChart<C: View>(_ chart: C) -> some View {
        if #available(iOS 17.0, *) {
            chart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: effectiveVisibleDomain)
                .chartScrollPosition(x: $scrollPosition)
        } else {
            ScrollView(.horizontal) {
                chart.frame(width: max(800, CGFloat(filteredFills.count) * 40))
            }
        }
    }
}

/// One figure in the iPad stats grid: an icon over a value over its label,
/// each in its own rounded card so six numbers read as a small dashboard
/// rather than a wall of text.
private struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: Circle())
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
