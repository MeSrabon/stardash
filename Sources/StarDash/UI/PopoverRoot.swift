import SwiftUI

/// What opens from the menu bar: one screen to glance at. Anything deeper lives in the main window.
struct PopoverRoot: View {
    static let size = CGSize(width: 380, height: 540)

    @Environment(TelemetryStore.self) private var store
    @Environment(SpeedTest.self) private var speedTest
    @Environment(AppActions.self) private var actions

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
            HStack(spacing: 8) {
                tile("Latency", state.isUp ? Fmt.ms(dish?.latencyMs) : Fmt.missing,
                     stats.medianLatency.map { String(format: "median %.0f ms", $0) })
                tile("Pings", Fmt.percent(stats.pingSuccess), "answered, 15 min")
                tile("Power", Fmt.watts(store.powerW), stats.avgPower.map { String(format: "avg %.0f W", $0) })
            }
            sky(dish)
            outage
            speedRow
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
                .frame(width: 150, height: 150)
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

    private var outage: some View {
        let recent = store.outages(since: 86_400)
        return HStack(spacing: 8) {
            Circle().fill(recent.isEmpty ? Color.white.opacity(0.3) : Palette.warn).frame(width: 6, height: 6)
            if let last = recent.first {
                Text("Last outage: \(last.title), \(Fmt.dayClock.string(from: last.start)), \(Fmt.duration(last.duration))")
                Spacer(minLength: 4)
                Text("\(recent.count) today").foregroundStyle(.white.opacity(0.4))
            } else {
                Text("No outages in the last 24 hours")
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
        .monospacedDigit()
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

