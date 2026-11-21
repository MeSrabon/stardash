import SwiftUI

/// What opens from the menu bar: one screen to glance at. Anything deeper lives in the main window.
struct PopoverRoot: View {
    static let size = CGSize(width: 380, height: 610)

    @Environment(TelemetryStore.self) private var store
    @Environment(SpeedTest.self) private var speedTest
    @Environment(AppActions.self) private var actions
    @State private var note: String?

    var body: some View {
        let state = store.state
        let dish = store.dish
        let stats = store.stats(900)
        VStack(alignment: .leading, spacing: 12) {
            header(state)
            HStack(alignment: .top, spacing: 0) {
                speed("arrow.down", "Download", dish?.downBps)
                speed("arrow.up", "Upload", dish?.upBps)
            }
            lastHour
            HStack(spacing: 8) {
                tile("Latency", state.isUp ? Fmt.ms(dish?.latencyMs) : Fmt.missing,
                     stats.medianLatency.map { String(format: "median %.0f ms", $0) })
                dataTile
                tile("Power", Fmt.watts(store.powerW), stats.avgPower.map { String(format: "avg %.0f W", $0) })
            }
            sky(dish)
            speedRow
            quickActions(dish)
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(.white)
        .background(Theme.isMono ? Color.black : Color(red: 0.06, green: 0.08, blue: 0.09))
        .environment(\.colorScheme, .dark)
        .overlay { OverlayHost(overlays: .popover) }
        .coordinateSpace(name: Overlays.space)
        .environment(Overlays.popover)
        .id(Theme.current)
        .onAppear { SkyWatch.shared.start(site: { store.site }, floor: { 90 - (store.map?.maxTheta ?? 80) }) }
        .task { if Account.shared.signedIn { await Account.shared.loadBilling() } }
        .onDisappear { SkyWatch.shared.stop() }
    }

    // MARK: Parts

    private func header(_ state: LinkState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(Color(nsColor: Palette.nsState(state))).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(Theme.title(state.title))
                    .font(Theme.display(26))
                    .kerning(Theme.isMono ? 1.2 : -0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let quality = store.quality { QualityBadge(quality: quality) }
        }
    }

    private var subtitle: String {
        guard let dish = store.dish else {
            return store.dishError.map { "Can't reach \(Settings.shared.dishHost): \($0)" } ?? "Looking for your dish"
        }
        var parts = [dish.modelName]
        if let uptime = dish.uptime { parts.append("up \(Fmt.duration(Double(uptime)))") }
        return parts.joined(separator: " · ")
    }

    private func speed(_ icon: String, _ label: String, _ bps: Double?) -> some View {
        let parts = splitUnit(Fmt.rate(bps, bytes: Settings.shared.useBytes))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Kicker(label)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.0).font(Theme.number(30)).monospacedDigit()
                Text(parts.1).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ label: String, _ value: String, _ caption: String?) -> some View {
        let parts = splitUnit(value)
        return VStack(alignment: .leading, spacing: 3) {
            Kicker(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts.0).font(Theme.number(19)).monospacedDigit()
                Text(parts.1).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(caption ?? " ").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.panelStroke))
    }

    /// The dish's view of the sky with the satellites in range, and what that view is like right now.
    private func sky(_ dish: DishStatus?) -> some View {
        let watch = SkyWatch.shared
        let wanted = UserDefaults.standard.object(forKey: "skySatellites") as? Bool ?? true
        let live = wanted && store.site != nil
        let best = live ? watch.bestPlaced(alignment: dish?.alignment, map: store.map) : nil
        let overlay = SkyOverlay(satellites: live ? watch.satellites : [], ahead: live ? watch.ahead : [:], best: best?.id)
        let inRange = overlay.satellites.filter { $0.elevation >= SkyWatch.serviceElevation }.count
        let obstructed = dish?.obstruction.currentlyObstructed == true
        return HStack(spacing: 14) {
            RadarDots(map: store.map, alignment: dish?.alignment, compact: true, sky: overlay)
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 8) {
                Kicker("Sky")
                fact(obstructed ? "Obstructed right now" : "Clear right now", obstructed ? Palette.warn : .white)
                fact("\(Fmt.percent(dish?.obstruction.fraction, digits: 2)) of the view blocked", .white.opacity(0.6))
                if inRange > 0 {
                    fact("\(inRange) satellites in range", .white.opacity(0.6))
                    if let best { fact("Best placed \(best.name)", .white.opacity(0.6)) }
                } else {
                    fact(store.map.map { "\(Fmt.percent($0.coverage, digits: 0)) of the sky mapped" } ?? "Waiting for the sky map", .white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.panelStroke))
    }

    private func fact(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8).monospacedDigit()
    }

    /// The last hour at a glance: latency as a line, outages as red marks. Answers "was that Starlink?"
    private var lastHour: some View {
        let outages = store.outages(since: 3600)
        let median = store.stats(3600).medianLatency
        var summary = outages.isEmpty ? "No outages" : "\(outages.count) \(outages.count == 1 ? "outage" : "outages")"
        if let median { summary += String(format: " · median %.0f ms", median) }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Kicker("Last hour")
                Spacer()
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(outages.isEmpty ? .white.opacity(0.5) : Palette.warn)
                    .monospacedDigit()
            }
            LastHourStrip(samples: Array(store.window(3600)), outages: outages)
                .frame(height: 34)
            if let last = outages.first {
                Text("Last: \(last.title) at \(Fmt.shortClock.string(from: last.start)), \(Fmt.duration(last.duration))")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).monospacedDigit()
            }
        }
        .padding(10)
        .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(Theme.panelStroke))
    }

    /// Data since midnight from the dish, and the billing cycle when signed in, since that's what a cap counts.
    private var dataTile: some View {
        let today = store.totals(MenuBarRenderer.hoursToday)
        var caption = "↓\(Fmt.data(today.down)) ↑\(Fmt.data(today.up))"
        if let usage = Account.shared.billing, let cycle = usage.cycles.last {
            caption = usage.unlimited || usage.limitGB == nil
                ? String(format: "cycle %.0f GB", cycle.totalGB)
                : String(format: "cycle %.0f of %.0f GB", cycle.totalGB, usage.limitGB ?? 0)
        }
        return tile("Today", Fmt.data(today.down + today.up), caption)
    }

    private func quickActions(_ dish: DishStatus?) -> some View {
        let settings = Settings.shared
        let reachable = dish != nil && store.dishError == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                action(dish?.stowRequested == true ? "Unstow" : "Stow", icon: "arrow.down.to.line") {
                    if dish?.stowRequested == true {
                        run("Unstow sent.") { await store.stowDish(false) }
                    } else {
                        Overlays.popover.confirm = ConfirmRequest(
                            title: "Stow the dish?",
                            message: "The dish folds flat for transport and goes offline until you unstow it.",
                            action: "Stow"
                        ) { run("Stow sent.") { await store.stowDish(true) } }
                    }
                }
                .disabled(!reachable)
                action("Restart", icon: "arrow.clockwise") {
                    Overlays.popover.confirm = ConfirmRequest(
                        title: "Restart the dish?",
                        message: "The internet drops for a minute or two while it starts up again.",
                        action: "Restart"
                    ) { run("Restart sent. Back in a minute or two.") { await store.rebootDish() } }
                }
                .disabled(!reachable)
                action(settings.alertsPaused ? "Resume alerts" : "Pause alerts",
                       icon: settings.alertsPaused ? "bell" : "bell.slash") {
                    settings.alertsPausedUntil = settings.alertsPaused ? nil : Date().addingTimeInterval(3600)
                }
                .help("Silences outage and dish notifications for an hour")
            }
            if let text = note ?? pausedNote {
                Text(text).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        }
    }

    private var pausedNote: String? {
        guard Settings.shared.alertsPaused, let until = Settings.shared.alertsPausedUntil else { return nil }
        return "Alerts paused until \(Fmt.shortClock.string(from: until))"
    }

    private func action(_ title: String, icon: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuietButton())
    }

    private func run(_ done: String, _ work: @escaping () async -> Bool) {
        Task {
            let ok = await work()
            note = ok ? done : "That didn't go through."
            try? await Task.sleep(for: .seconds(6))
            note = nil
        }
    }

    private var speedRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Kicker("Speed test")
                if speedTest.isRunning {
                    Text(String(format: "%@ · %.0f Mbps", speedTest.stage.title, speedTest.liveMbps))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                } else if let last = speedTest.last {
                    Text("↓ \(routeNumber(last.bestDown))  ↑ \(routeNumber(last.bestUp)) Mbps · \(Fmt.dayClock.string(from: last.date))")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                } else {
                    Text("Not run yet").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Button(speedTest.isRunning ? "Running…" : "Run") {
                Task { await speedTest.run(store: store) }
            }
            .buttonStyle(QuietButton())
            .disabled(speedTest.isRunning)
            .help("Uses real data, roughly 100 to 300 MB")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { actions.openMainWindow() } label: {
                Text(Theme.isMono ? "OPEN STARDASH" : "Open StarDash")
                    .font(.system(size: Theme.isMono ? 11 : 13, weight: .semibold))
                    .kerning(Theme.isMono ? 1.6 : 0)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(.white, in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            Button { actions.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("Settings")
        }
    }
}

struct QualityBadge: View {
    var quality: Quality

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(quality.score) / 100)
                    .stroke(Palette.quality(quality.score), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(quality.score)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 28, height: 28)
            Text(quality.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.quality(quality.score))
        }
        .help("Link quality over the last 2 minutes. \(quality.detail).")
    }
}


/// Latency over the last hour as a thin line, with red marks where pings were lost.
struct LastHourStrip: View {
    var samples: [Sample]
    var outages: [LinkEvent] = []
    private static let buckets = 120

    var body: some View {
        Canvas { context, size in
            let now = Date().timeIntervalSince1970
            let start = now - 3600
            var latency = [Float?](repeating: nil, count: Self.buckets)
            var lost = [Bool](repeating: false, count: Self.buckets)
            for s in samples {
                let i = Int((Double(s.t) - start) / 3600 * Double(Self.buckets))
                guard i >= 0, i < Self.buckets else { continue }
                if s.drop >= 1 { lost[i] = true }
                if s.drop < 1, s.latency > 0 { latency[i] = max(latency[i] ?? 0, s.latency) }
            }
            // The dish's own outage list, so the marks agree with the count above the strip.
            for o in outages {
                let a = Int((o.start.timeIntervalSince1970 - start) / 3600 * Double(Self.buckets))
                let b = Int((o.start.timeIntervalSince1970 + o.duration - start) / 3600 * Double(Self.buckets))
                for i in max(0, a)...max(max(0, a), min(Self.buckets - 1, b)) where i < Self.buckets { lost[i] = true }
            }
            let known = latency.compactMap { $0 }.sorted()
            let top = max(80, known.isEmpty ? 80 : known[min(known.count - 1, Int(Double(known.count) * 0.95))] * 1.15)
            let step = size.width / CGFloat(Self.buckets)

            // A faint baseline, so an empty or quiet hour still reads as a chart.
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.1)))
            for (i, isLost) in lost.enumerated() where isLost {
                context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * step, y: 0, width: max(1.5, step - 0.5), height: size.height), cornerRadius: 0.75),
                             with: .color(Palette.bad.opacity(0.85)))
            }
            var line = Path()
            var drawing = false
            for (i, value) in latency.enumerated() {
                guard let value else { drawing = false; continue }
                let p = CGPoint(x: (CGFloat(i) + 0.5) * step, y: size.height - 2 - (size.height - 4) * CGFloat(min(value, top) / top))
                if drawing { line.addLine(to: p) } else { line.move(to: p); drawing = true }
            }
            context.stroke(line, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .overlay(alignment: .bottomLeading) {
            if samples.isEmpty {
                Text("Collecting…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .accessibilityLabel("Latency over the last hour, with outages marked")
    }
}
