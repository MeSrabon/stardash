import SwiftUI
import Charts

/// Data, power and latency over time. Built from what StarDash records while it runs.
struct UsagePane: View {
    enum Section: String { case data, power, latency }

    @Environment(TelemetryStore.self) private var store
    @AppStorage("usageSection") private var sectionName = Section.data.rawValue
    @State private var hoursBack = 24

    private var section: Section { Section(rawValue: sectionName) ?? .data }

    private struct Bar: Identifiable {
        var id: Date { date }
        var date: Date
        var down = 0.0, up = 0.0, wh = 0.0, latency = 0.0
        var seconds = 0
    }

    /// Hourly bars for a day, daily bars for anything longer.
    private var bars: [Bar] {
        let buckets = store.hourly(hoursBack)
        if hoursBack <= 48 {
            return buckets.map {
                Bar(date: $0.date, down: $0.down, up: $0.up, wh: $0.wh,
                    latency: $0.latencyCount > 0 ? $0.latencySum / Double($0.latencyCount) : 0, seconds: $0.seconds)
            }
        }
        var days: [Date: (Bar, Double, Int)] = [:]
        for b in buckets {
            let day = Calendar.current.startOfDay(for: b.date)
            var entry = days[day] ?? (Bar(date: day), 0, 0)
            entry.0.down += b.down
            entry.0.up += b.up
            entry.0.wh += b.wh
            entry.0.seconds += b.seconds
            entry.1 += b.latencySum
            entry.2 += b.latencyCount
            days[day] = entry
        }
        return days.values.map { entry in
            var bar = entry.0
            bar.latency = entry.2 > 0 ? entry.1 / Double(entry.2) : 0
            return bar
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        let totals = store.totals(hoursBack)
        PaneScroll {
            HStack(alignment: .firstTextBaseline) {
                PaneTitle("Usage")
                Spacer()
                ChipPicker(options: [(Section.data, "Data"), (.power, "Power"), (.latency, "Latency")],
                           selection: Binding(get: { section }, set: { sectionName = $0.rawValue }))
            }
            HStack(alignment: .bottom) {
                switch section {
                case .data: dataHero(totals)
                case .power: powerHero(totals)
                case .latency: latencyHero
                }
                Spacer(minLength: 0)
                ChipPicker(options: [(24, "24h"), (168, "7d"), (720, "30d")], selection: $hoursBack)
                    .padding(.bottom, 4)
            }
            switch section {
            case .data:
                chartPanel("Data over time", unit: "GB", totals) { bar in
                    BarMark(x: .value("Time", bar.date, unit: hoursBack <= 48 ? .hour : .day), y: .value("GB", bar.down / 1e9))
                        .foregroundStyle(Palette.down)
                    BarMark(x: .value("Time", bar.date, unit: hoursBack <= 48 ? .hour : .day), y: .value("GB", bar.up / 1e9))
                        .foregroundStyle(Palette.up)
                }
                devices
            case .power:
                chartPanel("Energy over time", unit: "Wh", totals) { bar in
                    BarMark(x: .value("Time", bar.date, unit: hoursBack <= 48 ? .hour : .day), y: .value("Wh", bar.wh))
                        .foregroundStyle(Palette.power)
                }
            case .latency:
                chartPanel("Average latency over time", unit: "ms", totals) { bar in
                    BarMark(x: .value("Time", bar.date, unit: hoursBack <= 48 ? .hour : .day), y: .value("ms", bar.latency))
                        .foregroundStyle(Palette.accent)
                }
                histogram
            }
        }
    }

    // MARK: Heroes

    private func dataHero(_ t: UsageTotals) -> some View {
        HStack(alignment: .top, spacing: 34) {
            stat("Downloaded", Fmt.data(t.down))
            stat("Uploaded", Fmt.data(t.up))
            stat("Total", Fmt.data(t.down + t.up))
        }
    }

    private func powerHero(_ t: UsageTotals) -> some View {
        let average = t.seconds > 0 ? t.wh / (Double(t.seconds) / 3600) : nil
        return HStack(alignment: .top, spacing: 34) {
            stat("Right now", Fmt.watts(store.powerW))
            stat("Average", Fmt.watts(average))
            stat("Energy used", Fmt.energy(t.wh))
            stat("At this rate", average.map { Fmt.energy($0 * 24) + "/day" } ?? Fmt.missing)
        }
    }

    private var latencyHero: some View {
        let s = store.stats(900)
        let values = store.window(900).filter { $0.drop < 1 && $0.latency > 0 }.map { Double($0.latency) }.sorted()
        let p95 = values.isEmpty ? nil : values[min(values.count - 1, Int(Double(values.count) * 0.95))]
        return HStack(alignment: .top, spacing: 34) {
            stat("Right now", Fmt.ms(store.state.isUp ? store.dish?.latencyMs : nil))
            stat("Median, 15 min", Fmt.ms(s.medianLatency))
            stat("95th percentile", Fmt.ms(p95))
            stat("Jitter", Fmt.ms(s.jitter))
            if let router = store.router?.pingLatencyMs { stat("Router to internet", Fmt.ms(router)) }
        }
    }

    private func stat(_ label: String, _ formatted: String) -> some View {
        let parts = splitUnit(formatted)
        return HeroStat(label: label, value: parts.0, unit: parts.1)
    }

    // MARK: Panels

    private func chartPanel(_ title: String, unit: String, _ totals: UsageTotals,
                            @ChartContentBuilder marks: @escaping (Bar) -> some ChartContent) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title, trailing: String(format: "Recorded for %.0f%% of this window. Gaps are when StarDash wasn't running.", totals.coverage * 100))
                    .padding(.bottom, -6)
                if bars.isEmpty {
                    Text("Nothing recorded yet.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Chart(bars) { bar in marks(bar) }
                        // Ends at the close of the current hour or day so the newest bar stays inside the plot.
                        .chartXScale(domain: Date().addingTimeInterval(-Double(hoursBack) * 3600)...Date().addingTimeInterval(hoursBack <= 48 ? 3600 : 86_400))
                        .clipped()
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                                AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%g %@", v, unit)).font(.system(size: 9.5)) } }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                                AxisValueLabel(format: hoursBack <= 48 ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
                                    .font(.system(size: 9.5))
                            }
                        }
                        .frame(height: 190)
                }
            }
        }
    }

    private var devices: some View {
        let list = store.deviceUsage.values.filter { $0.down + $0.up > 0 }.sorted { $0.down + $0.up > $1.down + $1.up }
        let top = max(1, list.first.map { $0.down + $0.up } ?? 1)
        return Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Devices this month", trailing: "Counted from the router while StarDash runs")
                if list.isEmpty {
                    Text(store.router == nil ? "Needs a Starlink router." : "No traffic counted yet. Totals build up from now.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(.vertical, 12)
                }
                ForEach(list.prefix(20)) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(device.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text("↓ \(Fmt.data(device.down))   ↑ \(Fmt.data(device.up))")
                                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        }
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                Rectangle().fill(Palette.down).frame(width: max(2, geo.size.width * CGFloat(device.down / top)))
                                Rectangle().fill(Palette.up).frame(width: max(0, geo.size.width * CGFloat(device.up / top)))
                                Spacer(minLength: 0)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
            }
        }
    }

    /// How often each latency came up, which shows spikes an average hides.
    private var histogram: some View {
        let seconds = min(hoursBack * 3600, TelemetryStore.maxSamples)
        let values = store.window(seconds).filter { $0.drop < 1 && $0.latency > 0 }.map { Double($0.latency) }
        var bins = [Int](repeating: 0, count: 21)
        for v in values { bins[min(20, Int(v / 5))] += 1 }
        let total = max(1, values.count)
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader("How latency is spread", trailing: "Last \(hoursBack <= 24 ? "\(hoursBack) hours" : "24 hours"), share of pings")
                    .padding(.bottom, -6)
                Chart(Array(bins.enumerated()), id: \.offset) { index, count in
                    BarMark(x: .value("ms", index == 20 ? "100+" : "\(index * 5)"), y: .value("Share", Double(count) / Double(total) * 100))
                        .foregroundStyle(index >= 12 ? Palette.warn : Palette.accent)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%g%%", v)).font(.system(size: 9.5)) } }
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) } }
                .frame(height: 150)
            }
        }
    }
}
