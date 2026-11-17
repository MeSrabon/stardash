import SwiftUI
import Charts

/// Arc from the gauge's start (lower left) clockwise through `fraction` of its 270° sweep.
struct GaugeArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(135), endAngle: .degrees(135 + 270 * max(0.0001, min(1, fraction))), clockwise: false)
        return p
    }
}

enum GaugeScale {
    static let ticks: [Double] = [0, 5, 10, 25, 50, 100, 250, 500]

    /// Log-ish scale so 10 Mbps and 300 Mbps both land somewhere readable.
    static func fraction(_ mbps: Double) -> Double {
        min(1, log(1 + max(0, mbps) / 5) / log(1 + 500.0 / 5))
    }
}

struct SpeedGauge: View {
    var mbps: Double
    var color: Color
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let fraction = GaugeScale.fraction(mbps)
            ZStack {
                GaugeArc(fraction: 1)
                    .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                // Stacked translucent strokes fake a glow without a blur pass.
                GaugeArc(fraction: fraction)
                    .stroke(color.opacity(active ? 0.10 : 0), style: StrokeStyle(lineWidth: 38, lineCap: .round))
                GaugeArc(fraction: fraction)
                    .stroke(color.opacity(active ? 0.16 : 0), style: StrokeStyle(lineWidth: 26, lineCap: .round))
                GaugeArc(fraction: fraction)
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.35), color, .white], center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(135 + 270 * max(fraction, 0.02))),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .opacity(active || mbps > 0 ? 1 : 0)

                ForEach(GaugeScale.ticks, id: \.self) { tick in
                    let angle = (135 + 270 * GaugeScale.fraction(tick)) * .pi / 180
                    // Measured from the padded dial, which is what the arcs are drawn in.
                    let r = (side - 38) / 2 - 25
                    Text(tick >= 100 ? String(format: "%.0f", tick) : String(format: "%g", tick))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(mbps >= tick && active ? 0.85 : 0.32))
                        .position(x: (geo.size.width - 38) / 2 + cos(angle) * r, y: (geo.size.height - 38) / 2 + sin(angle) * r)
                }
            }
            .padding(19)
            .animation(.spring(duration: 0.45, bounce: 0.12), value: mbps)
            .animation(.easeInOut(duration: 0.4), value: color)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct SpeedPane: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(SpeedTest.self) private var test
    @State private var hoveringGo = false
    /// True only after a run finishes while this page is open. Coming back later starts clean.
    @State private var showResult = SpeedPane.stagedResult
    /// Set by the snapshot tool to render a finished result without running a test.
    static var stagedResult = false

    private var stageColor: Color {
        switch test.stage {
        case .latency: return Palette.good
        case .routerUp, .macUp: return Palette.up
        default: return Palette.down
        }
    }

    /// While running show the live run; otherwise the most recent saved result.
    private var shown: SpeedResult? { test.isRunning ? test.current : (showResult ? test.last : nil) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaneTitle("Speed")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.paneTop)

                Spacer(minLength: 8)
                gauge.frame(maxWidth: 380, maxHeight: 380)
                trace.frame(height: 46).frame(maxWidth: 380).padding(.top, -6)
                Spacer(minLength: 12)
                TestRoute(result: shown)
                    .frame(maxWidth: 640)
                if !verdict.isEmpty {
                    Text(verdict)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 10)
                }
                if let notice = test.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Palette.warn)
                        .multilineTextAlignment(.center).padding(.top, 8)
                }
                if let error = test.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.bad).padding(.top, 8)
                }
                Text("Uses real data, roughly 100 to 300 MB per run.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 10)
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            history
                .frame(width: 320)
                .padding(.top, Theme.paneTop)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
        }
        .onChange(of: test.isRunning) { was, now in
            if was, !now { showResult = test.error == nil }
        }
    }

    // MARK: Gauge

    private var gauge: some View {
        GeometryReader { geo in
            // Everything inside the dial shrinks with it, so the numbers never run into the ticks.
            let scale = min(1, min(geo.size.width, geo.size.height) / 380)
            ZStack {
                SpeedGauge(mbps: test.isRunning ? test.liveMbps : (showResult ? test.last?.bestDown ?? 0 : 0), color: stageColor, active: test.isRunning)

                Group {
                    if test.isRunning {
                        liveReadout.transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else if showResult, let last = test.last {
                        finalReadout(last).transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        goButton.transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .scaleEffect(scale)

                // Whole-run progress along the gap at the bottom of the dial.
                VStack {
                    Spacer()
                    Pillow().fill(.white.opacity(0.08))
                        .frame(width: 110, height: 3)
                        .overlay(alignment: .leading) {
                            Pillow().fill(stageColor).frame(width: 110 * test.progress, height: 3)
                                .animation(.linear(duration: 0.3), value: test.progress)
                        }
                        .opacity(test.isRunning ? 1 : 0)
                        .padding(.bottom, 34 * scale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(duration: 0.45), value: test.isRunning)
        }
    }

    private var liveReadout: some View {
        VStack(spacing: 2) {
            if test.stage == .latency {
                Text(test.current.latency.map { String(format: "%.0f", $0) } ?? "···")
                    .font(Theme.display(68)).monospacedDigit()
                Text("ms").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            } else {
                Text(test.liveMbps >= 100 ? String(format: "%.0f", test.liveMbps) : String(format: "%.1f", test.liveMbps))
                    .font(Theme.display(68)).monospacedDigit()
                Text("Mbps").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 6) {
                Image(systemName: test.stage.isUpload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(test.stage == .latency ? 0 : 1)
                Text(test.stage.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(1.2)
            }
            .foregroundStyle(stageColor)
            .padding(.top, 8)
        }
    }

    /// The finished result sits in the dial, where the eye already is.
    private func finalReadout(_ r: SpeedResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.down)
                Text("DOWNLOAD").font(.system(size: 10, weight: .semibold)).kerning(1.3).foregroundStyle(.white.opacity(0.5))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(r.bestDown.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? Fmt.missing)
                    .font(Theme.display(66)).monospacedDigit()
                Text("Mbps").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.up)
                Text(r.bestUp.map { String(format: "%.1f Mbps upload", $0) } ?? "No upload result")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
            Button {
                Task { await test.run(store: store) }
            } label: {
                Text(store.state.isUp ? "Test again" : "Test again (offline)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.white.opacity(hoveringGo ? 1 : 0.92), in: Pillow())
                    .contentShape(Pillow())
            }
            .buttonStyle(PressScale())
            .onHover { hoveringGo = $0 }
            .padding(.top, 16)
        }
    }

    /// The resting state: one clear thing to press, and what pressing it costs.
    private var goButton: some View {
        VStack(spacing: 14) {
            Button {
                Task { await test.run(store: store) }
            } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(hoveringGo ? 0.16 : 0.07), lineWidth: 1)
                        .frame(width: 196, height: 196)
                    Circle().strokeBorder(.white.opacity(hoveringGo ? 0.4 : 0.2), lineWidth: 1)
                        .frame(width: 164, height: 164)
                    Circle().fill(.white).frame(width: 132, height: 132)
                    Text("GO").font(.system(size: 34, weight: .semibold)).kerning(1.5).foregroundStyle(.black)
                }
                .scaleEffect(hoveringGo ? 1.05 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.4), value: hoveringGo)
                .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .onHover { hoveringGo = $0 }

            Text(store.state.isUp
                 ? "About \(seconds) seconds"
                 : "The link is offline right now")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(store.state.isUp ? .white.opacity(0.45) : Palette.warn)
        }
        .padding(.top, 26)
    }

    private var seconds: Int {
        let router = test.includeRouter && store.router != nil
        return router ? (test.includeMac ? 50 : 30) : 20
    }

    private var trace: some View {
        Sparkline(values: test.liveSeries, color: stageColor, minCeiling: 5)
            .opacity(test.isRunning && test.liveSeries.count > 1 ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: test.isRunning)
    }

    /// Latency and jitter of the run on screen. The path explains everything else itself.
    private var verdict: String {
        var parts: [String] = []
        if let latency = shown?.latency { parts.append(String(format: "Latency %.0f ms", latency)) }
        if let jitter = shown?.jitter { parts.append(String(format: "jitter %.1f ms", jitter)) }
        if let loss = shown?.loss {
            parts.append(loss <= 0 ? "no packet loss" : String(format: "%.0f%% packet loss", max(1, loss * 100)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("History", trailing: test.history.isEmpty ? nil : "\(test.history.count) runs")
                if !test.history.isEmpty {
                    Button("Clear") { test.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            if test.history.isEmpty {
                Card {
                    EmptyNote(icon: "speedometer", title: "No runs yet",
                              detail: "Results are saved here so you can see how your speed changes through the day.")
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        let macRuns = test.history.compactMap(\.macDown)
                        let best = macRuns.max() ?? 0
                        let avg = macRuns.reduce(0, +) / Double(max(1, macRuns.count))
                        HStack(spacing: 18) {
                            summary("This Mac best", macRuns.isEmpty ? Fmt.missing : String(format: "%.0f", best))
                            summary("Average", macRuns.isEmpty ? Fmt.missing : String(format: "%.0f", avg))
                            Spacer()
                        }
                        // Evenly spaced by run, oldest on the left. Spacing by clock time bunches runs into slivers.
                        Chart(Array(test.history.prefix(16).reversed().enumerated()), id: \.offset) { index, run in
                            BarMark(x: .value("Run", String(index)), y: .value("Mbps", run.macDown ?? 0), width: .fixed(5))
                                .foregroundStyle(Palette.down)
                                .position(by: .value("Source", "A"))
                                .cornerRadius(Theme.r(2))
                            BarMark(x: .value("Run", String(index)), y: .value("Mbps", run.routerDown ?? 0), width: .fixed(5))
                                .foregroundStyle(Palette.up.opacity(0.75))
                                .position(by: .value("Source", "B"))
                                .cornerRadius(Theme.r(2))
                        }
                        .chartXAxis(.hidden)
                        .chartLegend(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                                AxisValueLabel().font(.system(size: 9))
                            }
                        }
                        .frame(height: 84)
                        HStack(spacing: 14) {
                            sourceTag("laptopcomputer", "This Mac", Palette.down)
                            sourceTag("wifi.router", "Router", Palette.up)
                            Spacer()
                            Text("download, Mbps").foregroundStyle(.white.opacity(0.35))
                        }
                        .font(.system(size: 10.5))
                    }
                }

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(test.history) { run in historyRow(run) }
                    }
                }
                .scrollIndicators(.automatic)
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .semibold)).kerning(1).foregroundStyle(.white.opacity(0.45))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.number(22)).monospacedDigit()
                Text("Mbps").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func sourceTag(_ icon: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: Theme.r(2)).fill(color).frame(width: 8, height: 8)
            Image(systemName: icon).font(.system(size: 9.5))
            Text(label)
        }
        .foregroundStyle(.white.opacity(0.65))
    }

    /// One saved run. Each line says where it was measured from, so the two tests can't be mixed up.
    private func historyRow(_ run: SpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Fmt.dayClock.string(from: run.date)).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(run.latency.map { String(format: "%.0f ms", $0) } ?? "")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
            }
            if run.macDown != nil || run.macUp != nil {
                historyLine("laptopcomputer", "This Mac", run.macDown, run.macUp, strong: true)
            }
            if run.routerDown != nil || run.routerUp != nil {
                historyLine("wifi.router", "Router", run.routerDown, run.routerUp, strong: run.macDown == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.r(11), style: .continuous))
    }

    private func historyLine(_ icon: String, _ label: String, _ down: Double?, _ up: Double?, strong: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).frame(width: 16)
            Text(label).font(.system(size: 11.5))
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.down)
                Text(down.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? Fmt.missing)
                    .font(.system(size: 13, weight: strong ? .semibold : .regular))
            }
            .frame(width: 58, alignment: .trailing)
            HStack(spacing: 3) {
                Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.up)
                Text(up.map { String(format: "%.1f", $0) } ?? Fmt.missing)
                    .font(.system(size: 13, weight: strong ? .semibold : .regular))
            }
            .frame(width: 58, alignment: .trailing)
        }
        .monospacedDigit()
        .foregroundStyle(.white.opacity(strong ? 0.95 : 0.6))
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

/// Feeds the path under the gauge and owns the rules for switching start points on and off.
struct TestRoute: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(SpeedTest.self) private var test
    var result: SpeedResult?

    var body: some View {
        // Read everything here. State read only inside a GeometryReader closure didn't trigger a redraw.
        let stage = test.stage
        let found = store.router != nil
        let on = test.includeRouter && found
        let macOn = test.includeMac || !on
        let state = RouteState(
            macLive: stage == .latency || stage == .macDown || stage == .macUp,
            routerLive: stage == .routerDown || stage == .routerUp,
            found: found, on: on, running: test.isRunning,
            color: stage.isUpload ? Palette.up : Palette.down,
            result: result, macOn: macOn, upload: stage.isUpload)
        // The last start point can't be switched off; clicking it hands over to the other one.
        return RoutePick(state: state, toggleMac: {
            if !macOn { test.includeMac = true }
            else if on { test.includeMac = false }
            else if found { test.includeRouter = true; test.includeMac = false }
        }, toggleRouter: {
            if !on { if found { test.includeRouter = true } }
            else if macOn { test.includeRouter = false }
            else { test.includeMac = true; test.includeRouter = false }
        })
    }
}
