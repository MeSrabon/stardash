import SwiftUI

/// A popover tile that can open up into the last 24 hours.
enum PopoverDetail: Equatable {
    case latency, data, power

    var label: String {
        switch self {
        case .latency: return "Latency"
        case .data: return "Today"
        case .power: return "Power"
        }
    }
}

/// The last 24 hours of one tile, drawn where the sky card normally sits.
struct DetailCard: View {
    var kind: PopoverDetail
    var close: () -> Void

    @Environment(TelemetryStore.self) private var store
    private static let buckets = 96

    var body: some View {
        let series = self.series
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Kicker(kind == .data ? "Data · 24 h" : "\(kind.label) · 24 h")
                Spacer(minLength: 4)
                Text(series.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .lineLimit(1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to the sky")
            }
            ZStack(alignment: .topLeading) {
                chart(series)
                Text(series.topLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .monospacedDigit()
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("24 h ago")
                Spacer()
                Text("12 h")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.35))
        }
        .padding(10)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.panelStroke))
    }

    // MARK: Data

    private struct Series {
        var values: [Double?] = []
        var second: [Double?] = []
        var lost: [Bool] = []
        var top: Double = 1
        var topLabel = ""
        var summary = ""
        var bars = false
    }

    private var series: Series {
        switch kind {
        case .latency: return latencySeries
        case .power: return powerSeries
        case .data: return dataSeries
        }
    }

    /// Mean of each 15-minute slice, so a 24-hour line still has shape.
    private func bucketed(_ value: (Sample) -> Float?) -> (values: [Double?], lost: [Bool]) {
        let start = Date().timeIntervalSince1970 - 86_400
        var sums = [Double](repeating: 0, count: Self.buckets)
        var counts = [Int](repeating: 0, count: Self.buckets)
        var drops = [Int](repeating: 0, count: Self.buckets)
        for s in store.window(86_400) {
            let i = Int((Double(s.t) - start) / 86_400 * Double(Self.buckets))
            guard i >= 0, i < Self.buckets else { continue }
            if s.drop >= 1 { drops[i] += 1 }
            if let v = value(s) { sums[i] += Double(v); counts[i] += 1 }
        }
        let values = (0..<Self.buckets).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }
        var lost = drops.map { $0 >= 5 }
        for o in store.outages(since: 86_400) {
            let i = Int((o.start.timeIntervalSince1970 - start) / 86_400 * Double(Self.buckets))
            if i >= 0, i < Self.buckets { lost[i] = true }
        }
        return (values, lost)
    }

    private var latencySeries: Series {
        let b = bucketed { $0.drop < 1 && $0.latency > 0 ? $0.latency : nil }
        var s = Series(values: b.values, lost: b.lost)
        let known = b.values.compactMap { $0 }.sorted()
        let p95 = known.isEmpty ? 80 : known[min(known.count - 1, Int(Double(known.count) * 0.95))]
        s.top = max(60, (p95 * 1.2 / 20).rounded(.up) * 20)
        s.topLabel = String(format: "%.0f ms", s.top)
        let outages = store.outages(since: 86_400).count
        var parts: [String] = []
        if let median = store.stats(86_400).medianLatency { parts.append(String(format: "median %.0f ms", median)) }
        parts.append(outages == 0 ? "no outages" : "\(outages) \(outages == 1 ? "outage" : "outages")")
        s.summary = parts.joined(separator: " · ")
        return s
    }

    private var powerSeries: Series {
        let b = bucketed { $0.power > 0 ? $0.power : nil }
        var s = Series(values: b.values)
        let peak = b.values.compactMap { $0 }.max() ?? 50
        s.top = max(20, (peak * 1.15 / 10).rounded(.up) * 10)
        s.topLabel = String(format: "%.0f W", s.top)
        let wh = store.totals(24).wh
        var parts: [String] = []
        if let avg = store.stats(86_400).avgPower { parts.append(String(format: "avg %.0f W", avg)) }
        if wh > 0 { parts.append(String(format: "%.2f kWh", wh / 1000)) }
        s.summary = parts.joined(separator: " · ")
        return s
    }

    /// One bar per hour, download with upload stacked on top.
    private var dataSeries: Series {
        let now = Int(Date().timeIntervalSince1970) / 3600
        var down = [Double?](repeating: nil, count: 24)
        var up = [Double?](repeating: nil, count: 24)
        for h in store.hourly(24) {
            let i = 23 - (now - h.hour)
            guard i >= 0, i < 24 else { continue }
            down[i] = h.down
            up[i] = h.up
        }
        var s = Series(values: down, second: up, bars: true)
        let peak = zip(down, up).map { ($0 ?? 0) + ($1 ?? 0) }.max() ?? 0
        s.top = max(1, peak * 1.1)
        s.topLabel = Fmt.data(peak)
        let t = store.totals(24)
        s.summary = "↓\(Fmt.data(t.down)) ↑\(Fmt.data(t.up))"
        return s
    }

    // MARK: Drawing

    private func chart(_ s: Series) -> some View {
        Canvas { context, size in
            let n = s.values.count
            guard n > 0 else { return }
            let step = size.width / CGFloat(n)
            let h = size.height
            func y(_ v: Double) -> CGFloat { h - 1 - (h - 12) * CGFloat(min(v, s.top) / s.top) }

            // Midline and baseline, so a quiet day still reads as a chart.
            context.fill(Path(CGRect(x: 0, y: h - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.1)))
            var mid = Path()
            mid.move(to: CGPoint(x: size.width / 2, y: 10))
            mid.addLine(to: CGPoint(x: size.width / 2, y: h - 1))
            context.stroke(mid, with: .color(.white.opacity(0.06)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            if s.bars {
                for i in 0..<n {
                    let d = s.values[i] ?? 0
                    let u = s.second[i] ?? 0
                    guard d + u > 0 else { continue }
                    let x = CGFloat(i) * step + 1.5
                    let w = max(2, step - 3)
                    let downTop = y(d)
                    context.fill(Path(roundedRect: CGRect(x: x, y: downTop, width: w, height: h - 1 - downTop), cornerRadius: 1.5),
                                 with: .color(Palette.down.opacity(0.85)))
                    let upTop = y(d + u)
                    context.fill(Path(roundedRect: CGRect(x: x, y: upTop, width: w, height: max(0, downTop - upTop - 0.5)), cornerRadius: 1.5),
                                 with: .color(Palette.up.opacity(0.7)))
                }
                return
            }

            for (i, isLost) in s.lost.enumerated() where isLost {
                context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step, y: h - 8, width: max(1.5, step - 0.5), height: 7), cornerRadius: 0.75),
                             with: .color(Palette.bad.opacity(0.9)))
            }

            var line = Path()
            var area = Path()
            var runStart: CGFloat?
            var last: CGPoint?
            func closeArea() {
                if let x0 = runStart, let p = last {
                    area.addLine(to: CGPoint(x: p.x, y: h - 1))
                    area.addLine(to: CGPoint(x: x0, y: h - 1))
                    area.closeSubpath()
                }
                runStart = nil
                last = nil
            }
            for (i, value) in s.values.enumerated() {
                guard let value else { closeArea(); continue }
                let p = CGPoint(x: (CGFloat(i) + 0.5) * step, y: y(value))
                if last == nil {
                    line.move(to: p)
                    area.move(to: CGPoint(x: p.x, y: h - 1))
                    area.addLine(to: p)
                    runStart = p.x
                } else {
                    line.addLine(to: p)
                    area.addLine(to: p)
                }
                last = p
            }
            closeArea()
            let color: Color = kind == .power ? Palette.power : .white
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
            context.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .accessibilityLabel("\(kind.label) over the last 24 hours")
    }
}
