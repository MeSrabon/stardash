import SwiftUI

/// Hooks the SwiftUI views use to reach AppKit-owned things like the main window.
@MainActor
@Observable
final class AppActions {
    @ObservationIgnored var openMainWindow: () -> Void = {}
    /// Jumps the main window to a page. Set by the window itself.
    @ObservationIgnored var showPane: (Pane) -> Void = { _ in }
    @ObservationIgnored var openSettings: () -> Void = {}
}

private struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True in the main window, false in the menu bar popover.
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview, speed, sky, events, usage, network, device, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Dashboard"
        case .speed: return "Speed"
        case .sky: return "Sky"
        case .events: return "Events"
        case .usage: return "Usage"
        case .network: return "Network"
        case .device: return "Device"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "globe.americas.fill"
        case .speed: return "speedometer"
        case .sky: return "scope"
        case .events: return "waveform.path.ecg"
        case .usage: return "chart.bar.xaxis"
        case .network: return "wifi"
        case .device: return "cpu"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Window

struct MainWindow: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(AppActions.self) private var actions
    @State var pane: Pane = .overview
    @Namespace private var rail

    var body: some View {
        let mono = Theme.isMono
        let content = ZStack {
            switch pane {
            case .overview: DashboardPane()
            case .sky: SkyPane()
            case .speed: SpeedPane()
            case .settings: SettingsPane()
            case .events: EventsPane()
            case .usage: UsagePane()
            case .network: NetworkPane()
            case .device: DevicePane()
            }
        }
        .id(pane)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
            removal: .opacity
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        return Group {
            if mono {
                VStack(spacing: 0) {
                    topBar
                    content
                }
                .background(Color.black.ignoresSafeArea())
            } else {
                HStack(spacing: 0) {
                    sidebar
                    content
                }
                .background(backdrop)
            }
        }
        .id(Theme.current)
        .overlay { OverlayHost(overlays: .shared) }
        .coordinateSpace(name: Overlays.space)
        .environment(Overlays.shared)
        .onChange(of: pane) { Overlays.shared.menu = nil }
        .onAppear {
            actions.showPane = { target in withAnimation(.spring(duration: 0.38, bounce: 0.18)) { pane = target } }
        }
        .environment(\.wideLayout, true)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 940, minHeight: 640)
        .ignoresSafeArea()
    }

    /// Mono's navigation: a wordmark, text tabs with an underline, and the link state on the right.
    private var topBar: some View {
        HStack(alignment: .bottom, spacing: 20) {
            Text("STARDASH")
                .font(.custom("DIN Alternate", fixedSize: 16))
                .kerning(5)
                .fixedSize()
                .padding(.bottom, 13)
            ForEach(Pane.allCases) { p in
                let selected = pane == p
                Button {
                    withAnimation(.spring(duration: 0.38, bounce: 0.18)) { pane = p }
                } label: {
                    VStack(spacing: 11) {
                        Text(p.title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .kerning(1.5)
                            .foregroundStyle(selected ? .white : .white.opacity(0.45))
                        ZStack {
                            Color.clear.frame(height: 2)
                            if selected {
                                Rectangle().fill(.white).frame(height: 2).matchedGeometryEffect(id: "selection", in: rail)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            // The Dashboard already says the state in its headline, so the corner only appears elsewhere.
            if pane != .overview {
                // Drops the live speeds when the window is too narrow for them.
                ViewThatFits(in: .horizontal) {
                    corner(speeds: true)
                    corner(speeds: false)
                }
                .padding(.bottom, 13)
                .transition(.opacity)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 28)
        .frame(height: 74, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
    }

    private func corner(speeds: Bool) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(nsColor: Palette.nsState(store.state))).frame(width: 7, height: 7)
            Text(store.state.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.8)
            if speeds, let dish = store.dish {
                Text("↓ \(Fmt.rate(dish.downBps, bytes: Settings.shared.useBytes, compact: true))  ↑ \(Fmt.rate(dish.upBps, bytes: Settings.shared.useBytes, compact: true))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 6)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// Black, with a soft glow in the link's status color so the whole window reads the state at a glance.
    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Palette.state(store.state).opacity(0.16), .clear],
                center: UnitPoint(x: 0.78, y: 0.2), startRadius: 0, endRadius: 620
            )
            .animation(.easeInOut(duration: 1.2), value: store.state)
            LinearGradient(colors: [.white.opacity(0.03), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(spacing: 2) {
            Spacer().frame(height: 44)
            ForEach(Pane.allCases.filter { $0 != .settings }) { railButton($0) }
            Spacer()
            railButton(.settings)
            Spacer().frame(height: 12)
        }
        .frame(width: 84)
        .background(.white.opacity(0.03))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }

    private func railButton(_ p: Pane) -> some View {
        let selected = pane == p
        return Button {
            withAnimation(.spring(duration: 0.38, bounce: 0.18)) { pane = p }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous)
                            .fill(.white.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(.white.opacity(0.12)))
                            .matchedGeometryEffect(id: "selection", in: rail)
                    }
                    Image(systemName: p.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? .white : .white.opacity(0.45))
                }
                .frame(width: 46, height: 40)
                Text(p.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? .white.opacity(0.9) : .white.opacity(0.4))
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle())
    }
}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct PaneTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Theme.title(text)).font(Theme.number(26)).kerning(Theme.isMono ? 2 : 0.2)
    }
}

// MARK: - Dashboard

struct DashboardPane: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(AppActions.self) private var actions
    private var settings: Settings { Settings.shared }

    var body: some View {
        let dish = store.dish
        let stats = store.stats(900)
        let recent = Array(store.window(300))
        let outages = store.outages(since: 3600)

        let today = store.totals(24)
        let clients = (store.router?.clients ?? []).filter { !$0.isInfrastructure }
        let wireless = clients.filter(\.isWireless).count

        // Everything fits the window: the hero takes whatever height the tiles and the bottom row leave over.
        return GeometryReader { geo in
            let compact = geo.size.height < 690
            let lower = min(250, max(158, geo.size.height * 0.29))
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    hero(dish, compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    skyCard(dish).frame(width: compact ? 200 : 240).padding(.top, Theme.isMono ? 12 : 30)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    let latency = splitUnit(Fmt.ms(store.state.isUp ? dish?.latencyMs : nil))
                    GlassTile(title: "Latency", value: latency.0, unit: latency.1,
                              caption: "Median \(Fmt.ms(stats.medianLatency))",
                              color: Palette.accent, spark: recent.map { $0.drop >= 1 ? 0 : Double($0.latency) }, sparkCeiling: 60)
                        .onTapGesture { actions.showPane(.usage) }
                    let success = splitUnit(Fmt.percent(stats.pingSuccess))
                    GlassTile(title: "Ping success", value: success.0, unit: success.1, caption: "Last 15 minutes",
                              color: (stats.pingSuccess ?? 1) >= 0.99 ? Palette.good : Palette.warn,
                              spark: recent.map { 1 - Double($0.drop) }, sparkCeiling: 1)
                        .onTapGesture { actions.showPane(.events) }
                    let power = splitUnit(Fmt.watts(store.powerW))
                    GlassTile(title: "Power", value: power.0, unit: power.1,
                              caption: stats.avgPower.map { String(format: "Avg %.0f W", $0) } ?? "Not reported",
                              color: Palette.power, spark: recent.map { Double($0.power) }, sparkCeiling: 30)
                        .onTapGesture { actions.showPane(.usage) }
                    let obstruction = splitUnit(Fmt.percent(dish?.obstruction.fraction, digits: 2))
                    GlassTile(title: "Obstruction", value: obstruction.0, unit: obstruction.1,
                              caption: "\(outages.count) \(outages.count == 1 ? "outage" : "outages") this hour",
                              color: (dish?.obstruction.fraction ?? 0) < 0.01 ? Palette.good : Palette.warn, outages: outages)
                        .onTapGesture { actions.showPane(.sky) }
                    let data = splitUnit(Fmt.data(today.down + today.up))
                    GlassTile(title: "Data, 24h", value: data.0, unit: data.1,
                              caption: "↓ \(Fmt.data(today.down))  ↑ \(Fmt.data(today.up))",
                              color: Palette.down, spark: store.hourly(24).map { $0.down + $0.up }, sparkCeiling: 1)
                        .onTapGesture { actions.showPane(.usage) }
                    GlassTile(title: "Devices", value: store.router == nil ? Fmt.missing : "\(clients.count)", unit: "",
                              caption: store.router == nil ? "No Starlink router" : "\(wireless) Wi-Fi · \(clients.count - wireless) wired",
                              color: Palette.up)
                        .onTapGesture { actions.showPane(.network) }
                }

                HStack(alignment: .top, spacing: 12) {
                    HistoryChartCard(height: lower - 82)
                    eventsCard(height: lower).frame(width: compact ? 250 : 290)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
    }

    /// A small top-down sky map. Click to open the full Sky page.
    private func skyCard(_ dish: DishStatus?) -> some View {
        let obstructed = dish?.obstruction.currentlyObstructed == true
        // Follows the Satellites switch on the Sky page.
        let wanted = UserDefaults.standard.object(forKey: "skySatellites") as? Bool ?? true
        let watch = SkyWatch.shared
        let live = wanted && store.site != nil
        let best = live ? watch.bestPlaced(alignment: dish?.alignment, map: store.map) : nil
        let sky = SkyOverlay(satellites: live ? watch.satellites : [], ahead: live ? watch.ahead : [:], best: best?.id)
        let inRange = sky.satellites.filter { $0.elevation >= SkyWatch.serviceElevation }.count
        let mapped = store.map.map { "\(Fmt.percent($0.coverage, digits: 0)) of the sky mapped" } ?? "Waiting for the sky map"
        return Panel(padding: 12, fill: true) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Kicker("Sky")
                    Spacer()
                    Text(obstructed ? "Obstructed" : "Clear").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(obstructed ? Palette.bad : Palette.good)
                }
                RadarDots(map: store.map, alignment: dish?.alignment, compact: true, sky: sky)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { CompactSatelliteHover(sky: sky, maxTheta: store.map?.maxTheta ?? 80) }
                Text(inRange > 0 ? "\(inRange) satellites in range" : mapped)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(inRange > 0 ? 0.85 : 0.4)).lineLimit(1)
                    .monospacedDigit()
                if inRange > 0 {
                    Text(mapped).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.showPane(.sky) }
        .onAppear { SkyWatch.shared.start(site: { store.site }, floor: { 90 - (store.map?.maxTheta ?? 80) }) }
        .onDisappear { SkyWatch.shared.stop() }
    }

    private func eventsCard(height: CGFloat) -> some View {
        let recent = store.events.filter { $0.start >= Date().addingTimeInterval(-86_400) }
        let rows = max(1, Int((height - 46) / 31))
        return Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Kicker("Recent events")
                    Spacer()
                    Text("\(recent.count) today").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.bottom, 6)
                if recent.isEmpty {
                    Text("Nothing in the last 24 hours.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(recent.prefix(rows)) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.symbol).font(.system(size: 10.5)).foregroundStyle(event.tint).frame(width: 16)
                        Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        Text(event.duration > 0 ? Fmt.duration(event.duration) : "")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(height: 31)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { actions.showPane(.events) }
    }

    private func hero(_ dish: DishStatus?, compact: Bool) -> some View {
        let state = store.state
        return GeometryReader { area in
        ZStack(alignment: .leading) {
            HStack {
                Spacer(minLength: 0)
                GlobeView(
                    country: dish?.countryCode,
                    azimuth: dish?.alignment.azimuth, elevation: dish?.alignment.elevation,
                    color: Palette.state(state), online: state.isUp,
                    shell: SkyWatch.shared.shell
                )
                .onAppear { SkyWatch.shared.watchShell(true) }
                .onDisappear { SkyWatch.shared.watchShell(false) }
                .frame(width: max(300, area.size.height * 1.46), height: max(200, area.size.height))
                // Fade the bottom edge with an overlay. Masking the 3D view made SwiftUI redraw the hero in software every frame.
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: compact ? 30 : 70)

            VStack(alignment: .leading, spacing: 0) {
                Text(kicker(dish))
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.8)
                    .foregroundStyle(.white.opacity(0.5))

                HStack(spacing: 14) {
                    // Link state keeps its colour in both themes, matching the top bar and the menu bar.
                    PulseDot(color: Color(nsColor: Palette.nsState(state)))
                    Text(Theme.title(state.title))
                        .font(Theme.display(compact ? 40 : 54))
                        .kerning(Theme.isMono ? 1.5 : -0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: state)
                }
                .padding(.top, 6)

                Text(subline(dish))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 2)

                HStack(alignment: .top, spacing: 34) {
                    BigStat(label: "Download", icon: "arrow.down", formatted: Fmt.rate(dish?.downBps, bytes: settings.useBytes), color: Palette.down)
                    BigStat(label: "Upload", icon: "arrow.up", formatted: Fmt.rate(dish?.upBps, bytes: settings.useBytes), color: Palette.up)
                }
                .padding(.top, compact ? 14 : 30)

                if let q = store.quality {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.1), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: CGFloat(q.score) / 100)
                                .stroke(Palette.quality(q.score), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.spring(duration: 0.8), value: q.score)
                            Text("\(q.score)").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(q.label) link").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.quality(q.score))
                            Text(q.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.top, compact ? 12 : 28)
                }

                if let dish {
                    HStack(spacing: 6) {
                        ForEach(dish.alerts.filter { !DishStatus.benignAlerts.contains($0) }, id: \.self) {
                            Pill(text: $0, color: Palette.warn)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.top, Theme.isMono ? (compact ? 8 : 20) : (compact ? 26 : 44))
            .allowsHitTesting(false)
        }
        .frame(width: area.size.width, height: area.size.height, alignment: .topLeading)
        }
    }

    private func kicker(_ dish: DishStatus?) -> String {
        guard let dish else { return "STARDASH" }
        let country = dish.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        return [dish.modelName, country].compactMap { $0 }.joined(separator: "  ·  ").uppercased()
    }

    private func subline(_ dish: DishStatus?) -> String {
        guard let dish else {
            return store.dishError.map { "Can't reach \(settings.dishHost): \($0)" } ?? "Looking for your dish"
        }
        var parts: [String] = []
        if let uptime = dish.uptime { parts.append("Up \(Fmt.duration(Double(uptime)))") }
        if let sats = dish.gpsSats, dish.gpsValid == true { parts.append("\(sats) GPS satellites") }
        if let az = dish.alignment.azimuth { parts.append("pointing \(Fmt.compass(az))") }
        return parts.joined(separator: " · ")
    }
}

/// Pulsing status light. Core Animation runs the loop on the GPU; a SwiftUI repeatForever
/// animation here made the whole dashboard re-rasterize every frame.
struct PulseDot: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.wantsLayer = true
        view.layer?.masksToBounds = false

        let ring = CALayer()
        ring.name = "ring"
        ring.frame = NSRect(x: 1, y: 1, width: 14, height: 14)
        ring.cornerRadius = 7
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
        ring.opacity = 0
        view.layer?.addSublayer(ring)

        let core = CALayer()
        core.name = "core"
        core.frame = NSRect(x: 2, y: 2, width: 12, height: 12)
        core.cornerRadius = 6
        core.shadowOpacity = 0.9
        core.shadowRadius = 7
        core.shadowOffset = .zero
        view.layer?.addSublayer(core)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let cg = NSColor(color).cgColor
        for layer in view.layer?.sublayers ?? [] {
            layer.backgroundColor = cg
            if layer.name == "core" { layer.shadowColor = cg }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 16, height: 16)
    }
}

struct BigStat: View {
    var label: String
    var icon: String
    var formatted: String
    var color: Color

    var body: some View {
        let parts = splitUnit(formatted)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.2).foregroundStyle(.white.opacity(0.5))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(parts.0)
                    .font(Theme.number(40))
                    .monospacedDigit()
                Text(parts.1).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(minWidth: 130, alignment: .leading)
    }
}

/// Frosted tile that lifts slightly under the pointer.
struct GlassTile: View {
    var title: String
    var value: String
    var unit: String
    var caption: String
    var color: Color
    var spark: [Double] = []
    var sparkCeiling: Double = 1
    var outages: [LinkEvent]?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.1).foregroundStyle(.white.opacity(0.55))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.number(28))
                    .monospacedDigit()
                Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Group {
                if let outages {
                    OutageTimeline(events: outages, span: 3600).frame(height: 8).frame(height: 30)
                } else {
                    Sparkline(values: spark, color: color, minCeiling: sparkCeiling)
                }
            }
            .frame(height: 30)
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(hovering ? 0.085 : 0.05), in: RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.28 : 0.14), .white.opacity(0.03)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
        .onHover { hovering = $0 }
    }
}
