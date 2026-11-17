import SwiftUI
import Charts

enum ChartMetric: String, CaseIterable, Identifiable {
    case latency = "Latency"
    case throughput = "Throughput"
    case loss = "Ping loss"
    case power = "Power"

    var id: String { rawValue }
}

enum ChartRange: Int, CaseIterable, Identifiable {
    case m5 = 300, m15 = 900, h1 = 3600, h6 = 21_600, h24 = 86_400

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .m5: return "5m"
        case .m15: return "15m"
        case .h1: return "1h"
        case .h6: return "6h"
        case .h24: return "24h"
        }
    }
}

struct ChartPoint: Identifiable {
    var id: Int32 { t }
    var t: Int32
    var date: Date
    var latency: Double
    var loss: Double
    var down: Double
    var up: Double
    var power: Double
}

struct OverviewTab: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.wideLayout) private var wide

    private var settings: Settings { Settings.shared }

    var body: some View {
        let dish = store.dish
        let stats = store.stats(900)
        let recent = Array(store.window(300))

        VStack(spacing: 10) {
            banners

            LazyVGrid(columns: wide ? [GridItem(.adaptive(minimum: 210), spacing: 10)] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                let latency = splitUnit(Fmt.ms(store.state.isUp ? dish?.latencyMs : nil))
                StatTile(
                    title: "Latency", value: latency.0, unit: latency.1,
                    caption: "Median \(Fmt.ms(stats.medianLatency)) · jitter \(Fmt.ms(stats.jitter))",
                    color: Palette.accent,
                    spark: recent.map { $0.drop >= 1 ? 0 : Double($0.latency) }, sparkCeiling: 60
                )
                let success = splitUnit(Fmt.percent(stats.pingSuccess))
                StatTile(
                    title: "Ping success", value: success.0, unit: success.1,
                    caption: "Last 15 minutes",
                    color: (stats.pingSuccess ?? 1) >= 0.99 ? Palette.good : Palette.warn,
                    spark: recent.map { 1 - Double($0.drop) }, sparkCeiling: 1
                )
                let down = splitUnit(Fmt.rate(dish?.downBps, bytes: settings.useBytes))
                StatTile(
                    title: "Download", value: down.0, unit: down.1,
                    caption: "Peak \(Fmt.rate(stats.peakDown, bytes: settings.useBytes)) in 15m",
                    color: Palette.down,
                    spark: recent.map { Double($0.down) }, sparkCeiling: 1_000_000
                )
                let up = splitUnit(Fmt.rate(dish?.upBps, bytes: settings.useBytes))
                StatTile(
                    title: "Upload", value: up.0, unit: up.1,
                    caption: "Peak \(Fmt.rate(stats.peakUp, bytes: settings.useBytes)) in 15m",
                    color: Palette.up,
                    spark: recent.map { Double($0.up) }, sparkCeiling: 1_000_000
                )
                let power = splitUnit(Fmt.watts(store.powerW))
                StatTile(
                    title: "Power draw", value: power.0, unit: power.1,
                    caption: stats.avgPower.map { String(format: "Avg %.0f W · %.0f Wh/day", $0, $0 * 24) } ?? "Not reported by this dish",
                    color: Palette.power,
                    spark: recent.map { Double($0.power) }, sparkCeiling: 30
                )
                let obstruction = splitUnit(Fmt.percent(dish?.obstruction.fraction, digits: 2))
                let outages = store.outages(since: 3600)
                StatTile(
                    title: "Obstruction", value: obstruction.0, unit: obstruction.1,
                    caption: "\(outages.count) \(outages.count == 1 ? "outage" : "outages") in the last hour",
                    color: (dish?.obstruction.fraction ?? 0) < 0.01 ? Palette.good : Palette.warn,
                    outages: outages
                )
            }

            HistoryChartCard()
        }
    }

    @ViewBuilder
    private var banners: some View {
        if store.dish == nil, let error = store.dishError {
            Banner(icon: "wifi.exclamationmark", text: "Dish unreachable: \(error)", color: .gray)
        }
        if let dish = store.dish {
            if case .offline(let why) = store.state {
                Banner(icon: "bolt.horizontal.circle", text: "Offline: \(why)", color: Palette.bad)
            }
            ForEach(dish.alerts.filter { !DishStatus.benignAlerts.contains($0) }, id: \.self) { alert in
                Banner(icon: "exclamationmark.triangle.fill", text: alert, color: Palette.warn)
            }
            if dish.softwareUpdateState == 6 {
                Banner(icon: "arrow.triangle.2.circlepath", text: "Firmware update ready, reboot pending", color: Palette.accent)
            }
            if let limit = dish.dlRestricted, limit > 1 {
                Banner(icon: "tortoise.fill", text: Names.rateLimit(limit) ?? "Download speed limited", color: Palette.warn)
            }
        }
    }
}

/// History chart with a metric picker, a range picker and hover readout.
struct HistoryChartCard: View {
    @Environment(TelemetryStore.self) private var store
    @State private var metric: ChartMetric = .latency
    @State private var range: ChartRange = .m15
    @State private var selection: Date?
    var height: CGFloat = 150

    private var points: [ChartPoint] {
        let slice = store.window(range.rawValue)
        guard !slice.isEmpty else { return [] }
        let bucket = max(1, range.rawValue / 240)
        var out: [ChartPoint] = []
        var i = slice.startIndex
        while i < slice.endIndex {
            let key = slice[i].t / Int32(bucket)
            var n = 0.0, lat = 0.0, latN = 0.0, loss = 0.0, down = 0.0, up = 0.0, power = 0.0
            while i < slice.endIndex, slice[i].t / Int32(bucket) == key {
                let s = slice[i]
                n += 1
                if s.drop < 1, s.latency > 0 { lat += Double(s.latency); latN += 1 }
                loss += Double(min(1, max(0, s.drop)))
                down = max(down, Double(s.down))
                up = max(up, Double(s.up))
                power += Double(s.power)
                i += 1
            }
            let t = key * Int32(bucket)
            out.append(ChartPoint(
                t: t, date: Date(timeIntervalSince1970: Double(t)),
                latency: latN > 0 ? lat / latN : 0, loss: loss / n * 100,
                down: down / 1e6, up: up / 1e6, power: power / n
            ))
        }
        return out
    }

    var body: some View {
        let data = points
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    DropPicker(options: ChartMetric.allCases.map { ($0, $0.rawValue) }, selection: $metric)
                    Spacer()
                    ChipPicker(options: ChartRange.allCases.map { ($0, $0.label) }, selection: $range, pad: 9)
                }

                if data.count < 2 {
                    EmptyNote(icon: "chart.xyaxis.line", title: "Collecting history",
                              detail: "The chart fills in once the dish has reported a few seconds of data.")
                        .frame(height: 150)
                } else {
                    chart(data).frame(height: height)
                    legend(data)
                }
            }
        }
    }

    private func chart(_ data: [ChartPoint]) -> some View {
        Chart {
            switch metric {
            case .latency:
                ForEach(data) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("ms", p.latency))
                        .foregroundStyle(.linearGradient(colors: [Palette.accent.opacity(0.3), Palette.accent.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.date), y: .value("ms", p.latency))
                        .foregroundStyle(Palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            case .throughput:
                ForEach(data) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Mbps", p.down), series: .value("Dir", "Down"))
                        .foregroundStyle(Palette.down)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    LineMark(x: .value("Time", p.date), y: .value("Mbps", p.up), series: .value("Dir", "Up"))
                        .foregroundStyle(Palette.up)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            case .loss:
                ForEach(data) { p in
                    BarMark(x: .value("Time", p.date), y: .value("%", p.loss), width: .fixed(1.5))
                        .foregroundStyle(p.loss >= 50 ? Palette.bad : Palette.warn)
                }
            case .power:
                ForEach(data) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("W", p.power))
                        .foregroundStyle(.linearGradient(colors: [Palette.power.opacity(0.3), Palette.power.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.date), y: .value("W", p.power))
                        .foregroundStyle(Palette.power)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
            if let selection {
                RuleMark(x: .value("Time", selection))
                    .foregroundStyle(.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: 0...yCeiling(data))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel(format: range.rawValue > 3600 ? .dateTime.hour() : .dateTime.hour().minute())
                    .font(.system(size: 9.5))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel().font(.system(size: 9.5))
            }
        }
    }

    private func yCeiling(_ data: [ChartPoint]) -> Double {
        switch metric {
        case .latency: return max(60, (data.map(\.latency).max() ?? 0) * 1.15)
        case .throughput: return max(1, (data.map { max($0.down, $0.up) }.max() ?? 0) * 1.15)
        case .loss: return max(5, min(100, (data.map(\.loss).max() ?? 0) * 1.15))
        case .power: return max(30, (data.map(\.power).max() ?? 0) * 1.15)
        }
    }

    @ViewBuilder
    private func legend(_ data: [ChartPoint]) -> some View {
        let picked = selection.flatMap { sel in data.min { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) } }
        HStack(spacing: 10) {
            if let p = picked {
                Text(Fmt.clock.string(from: p.date)).foregroundStyle(.secondary)
                switch metric {
                case .latency: Text(String(format: "%.0f ms", p.latency))
                case .throughput:
                    Text(String(format: "↓ %.1f Mbps", p.down)).foregroundStyle(Palette.down)
                    Text(String(format: "↑ %.1f Mbps", p.up)).foregroundStyle(Palette.up)
                case .loss: Text(String(format: "%.1f%% lost", p.loss))
                case .power: Text(String(format: "%.1f W", p.power))
                }
            } else {
                switch metric {
                case .latency: Text("Round trip to the Starlink point of presence")
                case .throughput:
                    Label("Down", systemImage: "circle.fill").foregroundStyle(Palette.down)
                    Label("Up", systemImage: "circle.fill").foregroundStyle(Palette.up)
                    Text("Mbps, all devices").foregroundStyle(.tertiary)
                case .loss: Text("Share of pings dropped per interval")
                case .power: Text("Watts at the dish input")
                }
            }
            Spacer()
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .labelStyle(TinyDotLabel())
    }
}

private struct TinyDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}
