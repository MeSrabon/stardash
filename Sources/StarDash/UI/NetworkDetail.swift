import Charts
import SwiftUI

/// Averages a time series into a fixed number of slots so a day of points draws as fast as a minute.
private func bucketed(_ points: [(t: Int32, v: Float)], from start: Int32, span: Int32, slots: Int = 200) -> [(date: Date, value: Double)] {
    guard span > 0 else { return [] }
    var sums = [Double](repeating: 0, count: slots)
    var counts = [Int](repeating: 0, count: slots)
    for p in points where p.t >= start {
        let i = min(slots - 1, Int(Int64(p.t - start) * Int64(slots) / Int64(span)))
        sums[i] += Double(p.v)
        counts[i] += 1
    }
    return (0..<slots).compactMap { i in
        guard counts[i] > 0 else { return nil }
        let t = Double(start) + (Double(i) + 0.5) * Double(span) / Double(slots)
        return (Date(timeIntervalSince1970: t), sums[i] / Double(counts[i]))
    }
}

private func median(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.sorted()[values.count / 2]
}

// MARK: Latency comparison

/// The dish and the router each ping Starlink's ground station. Drawn together, the gap between
/// the two lines is what the cable and the router add, and the top line shows the internet beyond.
struct LatencyCompare: View {
    @Environment(TelemetryStore.self) private var store
    @State private var minutes = 60

    private struct Mark: Identifiable {
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
        var series: String
        var date: Date
        var value: Double
    }

    private static let dishName = "Dish to ground station"
    private static let routerName = "Router to ground station"
    private static let netName = "Router to internet"

    private var colors: [(String, Color)] {
        [(Self.dishName, Palette.accent), (Self.routerName, Palette.up),
         (Self.netName, Theme.isMono ? .white.opacity(0.4) : Palette.good)]
    }

    var body: some View {
        let now = Int32(Date().timeIntervalSince1970)
        let span = Int32(minutes * 60)
        let start = now - span
        let dish = bucketed(store.window(minutes * 60).filter { $0.drop < 1 && $0.latency > 0 }.map { ($0.t, $0.latency) }, from: start, span: span)
        let recent = store.pings.filter { $0.t >= start }
        let router = bucketed(recent.filter { $0.pop >= 0 }.map { ($0.t, $0.pop) }, from: start, span: span)
        let net = bucketed(recent.filter { $0.internet >= 0 }.map { ($0.t, $0.internet) }, from: start, span: span)
        let marks = dish.map { Mark(series: Self.dishName, date: $0.date, value: $0.value) }
            + router.map { Mark(series: Self.routerName, date: $0.date, value: $0.value) }
            + net.map { Mark(series: Self.netName, date: $0.date, value: $0.value) }
        let dishMid = median(dish.map(\.value)), routerMid = median(router.map(\.value)), netMid = median(net.map(\.value))

        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Kicker("Latency: dish against router")
                    Spacer()
                    ChipPicker(options: [(15, "15m"), (60, "1h"), (360, "6h"), (1440, "24h")], selection: $minutes, pad: 10)
                }
                HStack(spacing: 28) {
                    figure(Self.dishName, dishMid)
                    figure(Self.routerName, routerMid)
                    figure(Self.netName, netMid)
                    Spacer(minLength: 0)
                }
                if router.count < 2 {
                    Text("The router's pings are recorded while StarDash runs. This fills in over the next minute.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    Chart(marks) { mark in
                        LineMark(x: .value("Time", mark.date), y: .value("ms", mark.value), series: .value("Series", mark.series))
                            .foregroundStyle(by: .value("Series", mark.series))
                            .lineStyle(StrokeStyle(lineWidth: mark.series == Self.dishName ? 1.8 : 1.3,
                                                   dash: mark.series == Self.netName ? [3, 3] : []))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(domain: colors.map(\.0), range: colors.map(\.1))
                    .chartLegend(.hidden)
                    .chartXScale(domain: Date(timeIntervalSince1970: Double(start))...Date(timeIntervalSince1970: Double(now)))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.06))
                            AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%g ms", v)).font(.system(size: 9.5)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9.5))
                        }
                    }
                    .frame(height: 170)
                }
                if let line = summary(dish: dishMid, router: routerMid, net: netMid) {
                    Text(line).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func figure(_ name: String, _ value: Double?) -> some View {
        let color = colors.first { $0.0 == name }?.1 ?? .white
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Line().stroke(color, style: StrokeStyle(lineWidth: 2, dash: name == Self.netName ? [3, 3] : []))
                    .frame(width: 16, height: 2)
                Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.0f", $0) } ?? Fmt.missing).font(Theme.number(22)).monospacedDigit()
                Text("ms").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func summary(dish: Double?, router: Double?, net: Double?) -> String? {
        guard let dish, let router else { return nil }
        let gap = router - dish
        var text = abs(gap) < 3
            ? "The router sees the same latency as the dish, so the cable and router add nothing."
            : gap > 0 ? String(format: "The router sees %.0f ms more than the dish. That's the cable and the router itself.", gap)
                      : String(format: "The router reads %.0f ms lower than the dish, which is within how differently the two measure.", -gap)
        if let net, net - router >= 3 {
            text += String(format: " Reaching the wider internet adds another %.0f ms.", net - router)
        }
        return text
    }
}

// MARK: Mesh

/// Extra Starlink routers extending the network.
struct MeshNodes: View {
    var nodes: [WifiClient]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Mesh nodes", trailing: "\(nodes.count) extending the network")
                ForEach(nodes) { node in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.router").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).frame(width: 20)
                        Text(node.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text([node.ip, node.isWireless ? "wireless link on \(node.ifaceName)" : "wired link"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer()
                        if node.isWireless {
                            if let signal = node.signal {
                                Text(String(format: "%.0f dBm", signal)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                            }
                            SignalBars(dBm: node.signal)
                        }
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: Device detail

/// Everything known about one device, with its signal and traffic over the time StarDash has watched it.
struct DeviceDetail: View {
    @Environment(TelemetryStore.self) private var store
    var id: String
    /// Kept so the card still has a name if the device drops off while it's open.
    var name: String
    /// The router's own fifteen minutes for this device, refreshed while the card is open.
    @State private var remembered: [DevicePoint] = []

    var body: some View {
        let client = store.router?.clients.first { $0.id == id }
        let series = remembered.count >= 2 ? remembered : store.deviceSeries[id] ?? []
        let isMac = client?.ip.map(store.localIPs.contains) ?? false
        let vendor = Vendors.shared.name(for: client?.mac)

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconBadge(icon: isMac ? "laptopcomputer" : client?.isWireless == false ? "cable.connector" : "wifi",
                          tint: isMac ? Palette.accent : .white.opacity(0.8), size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(client?.name ?? name).font(Theme.number(22)).lineLimit(1)
                        if isMac { Pill(text: "This Mac", color: Palette.accent) }
                        if client?.blocked == true { Pill(text: "Blocked", color: Palette.bad) }
                    }
                    Text(client == nil ? "Not on the network right now" : [vendor, client?.ifaceName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 30)
            }

            if let client {
                HStack(alignment: .top, spacing: 28) {
                    if client.isWireless {
                        HeroStat(label: "Signal", value: client.signal.map { String(format: "%.0f", $0) } ?? Fmt.missing, unit: "dBm")
                        HeroStat(label: "Noise margin", value: client.snr.map { String(format: "%.0f", $0) } ?? Fmt.missing, unit: "dB")
                        HeroStat(label: "Link rate", value: client.txRateMbps.flatMap { $0 > 0 ? String(format: "%.0f", $0) : nil } ?? Fmt.missing, unit: "Mbps")
                    }
                    HeroStat(label: "Connected", value: Fmt.duration(client.associatedSeconds.map(Double.init)))
                    Spacer(minLength: 0)
                }

                if series.count < 2 {
                    Text("Charts appear once the router has a few seconds of history for this device.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Kicker("Traffic")
                            Spacer()
                            Text(remembered.count >= 2 ? "Last 15 minutes, from the router" : "Since StarDash started watching")
                                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                        }
                        trafficChart(series)
                    }
                    // The router's history often leaves signal out, so fall back to what StarDash recorded itself.
                    let signal = [series, store.deviceSeries[id] ?? []].map { $0.filter { $0.signal < 0 } }.first { $0.count >= 2 } ?? []
                    if client.isWireless, !signal.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Kicker("Signal")
                            signalChart(signal)
                        }
                    }
                }

                VStack(spacing: 0) {
                    Fact("IP address", client.ip)
                    Fact("Hardware address", client.mac)
                    Fact("Maker", vendor)
                    if client.isWireless, let w = client.channelWidth, w > 0 { Fact("Channel width", "\(w) MHz") }
                    if let usage = store.deviceUsage[client.mac ?? client.name], usage.down + usage.up > 0 {
                        Fact("This month", "↓ \(Fmt.data(usage.down))   ↑ \(Fmt.data(usage.up))")
                    }
                }
            }
        }
        .padding(22)
        .onAppear { Vendors.shared.loadIfNeeded() }
        .task(id: id) {
            while !Task.isCancelled {
                if let device = store.router?.clients.first(where: { $0.id == id }) {
                    let points = await store.clientHistory(device)
                    if points.count >= 2 { remembered = points }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func trafficChart(_ series: [DevicePoint]) -> some View {
        let bytes = Settings.shared.useBytes
        return Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.date), y: .value("Rate", Double(p.down) * 8), series: .value("Series", "Download"))
                    .foregroundStyle(Palette.down)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Rate", Double(p.up) * 8), series: .value("Series", "Upload"))
                    .foregroundStyle(Palette.up)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.rate(v, bytes: bytes, compact: true)).font(.system(size: 9.5)) } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9.5)) } }
        .frame(height: 96)
    }

    private func signalChart(_ series: [DevicePoint]) -> some View {
        Chart(Array(series.enumerated()), id: \.offset) { _, p in
            LineMark(x: .value("Time", p.date), y: .value("dBm", Double(p.signal)))
                .foregroundStyle(Palette.accent)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: -95...(-25))
        .chartYAxis {
            AxisMarks(position: .leading, values: [-90, -70, -50, -30]) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.0f", v)).font(.system(size: 9.5)) } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9.5)) } }
        .frame(height: 80)
    }
}
