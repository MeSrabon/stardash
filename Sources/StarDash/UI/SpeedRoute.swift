import SwiftUI

/// What the path under the gauge needs to know about the test, read once per redraw.
struct RouteState {
    var macLive: Bool
    var routerLive: Bool
    var found: Bool
    var on: Bool
    var running: Bool
    var color: Color
    var result: SpeedResult?
    /// Whether a test starts at this Mac.
    var macOn = true
    var upload = false

    /// Share of the router's download speed that never reaches this Mac.
    var wifiLoss: Double? {
        guard on, let mac = result?.macDown, let router = result?.routerDown, router > 0 else { return nil }
        return max(0, 1 - mac / router)
    }

    var lossLine: String? {
        guard let loss = wifiLoss else { return nil }
        return loss < 0.08 ? "Wi-Fi is keeping up. Almost nothing lost."
            : "Wi-Fi is costing you \(Int((loss * 100).rounded()))% of your speed."
    }
}

func routeNumber(_ value: Double?) -> String {
    value.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? Fmt.missing
}

/// Down and up figures on one line.
struct RouteFigures: View {
    var down: Double?
    var up: Double?
    var size: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            figure("arrow.down", Palette.down, down)
            figure("arrow.up", Palette.up, up)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func figure(_ icon: String, _ color: Color, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: icon).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(color)
            Text(routeNumber(value)).font(Theme.number(size)).monospacedDigit()
        }
    }
}

// MARK: Start point

/// The path is the control. Click This Mac or the router to start a test there; each start point
/// draws a run from itself to the internet, so what will be tested is on screen before pressing go.
struct RoutePick: View {
    var state: RouteState
    var toggleMac: () -> Void
    var toggleRouter: () -> Void
    private let nodeWidth: CGFloat = 76

    var body: some View {
        let both = state.macOn && state.on
        return GeometryReader { geo in
            let gap = max(0, (geo.size.width - nodeWidth * 4) / 3)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    StartNode(icon: "laptopcomputer", name: "This Mac", on: state.macOn, live: state.macLive,
                              color: state.color, enabled: !state.running && (state.found || !state.macOn), action: toggleMac)
                    link("Wi-Fi", covered: state.macOn, lit: state.macLive)
                    StartNode(icon: "wifi.router", name: "Router", on: state.on, live: state.routerLive || state.macLive,
                              color: state.color, enabled: !state.running && state.found, action: toggleRouter)
                    link("Cable", covered: true, lit: state.macLive || state.routerLive)
                    endNode("antenna.radiowaves.left.and.right", "Dish")
                    link("Satellite", covered: true, lit: state.macLive || state.routerLive)
                    endNode("globe", "Internet")
                }
                run("This Mac", to: "Internet", seconds: 20, on: state.macOn, live: state.macLive,
                    down: state.result?.macDown, up: state.result?.macUp, action: toggleMac)
                    .padding(.leading, nodeWidth / 2 - 5)
                    .padding(.top, 8)
                run("Router", to: "Internet", seconds: 30, on: state.on, live: state.routerLive,
                    down: state.result?.routerDown, up: state.result?.routerUp, action: toggleRouter)
                    .padding(.leading, nodeWidth * 1.5 + gap - 5)
                    .padding(.top, 4)
                Text(summary(both: both))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(state.wifiLoss != nil && both ? 0.9 : 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
            .padding(.trailing, nodeWidth / 2 - 5)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: state.on)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: state.macOn)
        }
        .frame(height: 160)
    }

    private func summary(both: Bool) -> String {
        if both, let line = state.lossLine { return line }
        if !state.found { return "No Starlink router found, so tests start at this Mac." }
        if both { return "Two tests, about 50 seconds. The gap between them is what Wi-Fi costs you." }
        if state.on { return "Starts at the router, so Wi-Fi is left out. About 30 seconds. Click This Mac to add it." }
        return "Starts at this Mac and includes Wi-Fi. About 20 seconds. Click the router to start there too."
    }

    /// One test, drawn from where it starts to where it ends. A faint dashed one is a test that's switched off.
    private func run(_ from: String, to: String, seconds: Int, on: Bool, live: Bool,
                     down: Double?, up: Double?, action: @escaping () -> Void) -> some View {
        let ink = live ? state.color : Color.white.opacity(on ? 0.85 : 0.22)
        let style = StrokeStyle(lineWidth: on ? 1.5 : 1, dash: on ? [] : [3, 4])
        return Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(on ? ink : .clear).overlay(Circle().strokeBorder(ink, lineWidth: 1.5)).frame(width: 10, height: 10)
                Line().stroke(ink, style: style).frame(width: 18, height: 1)
                HStack(spacing: 6) {
                    if !on { Image(systemName: "plus").font(.system(size: 8, weight: .bold)) }
                    Text(from.uppercased())
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).opacity(0.6)
                    Text(to.uppercased())
                }
                .font(.system(size: 9.5, weight: .semibold)).kerning(1.2)
                .foregroundStyle(.white.opacity(on ? 0.8 : 0.4))
                .fixedSize()
                if on {
                    if down != nil || up != nil || live {
                        RouteFigures(down: down, up: up, size: 16)
                    } else {
                        Text("\(seconds) s").font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4)).fixedSize()
                    }
                }
                Line().stroke(ink, style: style).frame(height: 1)
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(ink)
                    .padding(.leading, -8)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not .disabled, which would grey the path out for the whole test.
        .allowsHitTesting(!state.running)
        .animation(.easeInOut(duration: 0.25), value: live)
    }

    private func endNode(_ icon: String, _ name: String) -> some View {
        let lit = state.macLive || state.routerLive
        return VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(lit ? 1 : 0.7))
                .frame(width: 36, height: 36)
                .background(lit ? state.color.opacity(0.45) : .white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(lit ? state.color : .white.opacity(0.12)))
            Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.9 : 0.5))
        }
        .frame(width: nodeWidth)
    }

    private func link(_ name: String, covered: Bool, lit: Bool) -> some View {
        VStack(spacing: 3) {
            Text(name).font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(lit ? 0.75 : covered ? 0.5 : 0.2))
                .strikethrough(!covered, color: .white.opacity(0.3))
            Line().stroke(lit ? state.color.opacity(0.4) : .white.opacity(covered ? 0.4 : 0.14),
                          style: StrokeStyle(lineWidth: 1, dash: covered ? [] : [3, 4]))
                .frame(height: 2)
                // Data on the move: toward this Mac for a download, toward the internet for an upload.
                .overlay { FlowDots(active: lit, towardStart: !state.upload, color: state.color).frame(height: 8) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -12)
        .padding(.bottom, 26)
        .animation(.easeInOut(duration: 0.3), value: lit)
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A device a test can start from. Filled means a test starts here; a plus badge means it can be added.
struct StartNode: View {
    var icon: String
    var name: String
    var on: Bool
    var live: Bool
    var color: Color
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(on && !live ? .black : .white.opacity(on ? 1 : 0.75))
                    .frame(width: 36, height: 36)
                    .background(live && on ? color.opacity(0.45) : .white.opacity(on ? 1 : hovering ? 0.16 : 0.06), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(on ? 0 : hovering ? 0.8 : 0.4),
                                                   style: StrokeStyle(lineWidth: 1, dash: on ? [] : [3, 3])))
                    .overlay(Circle().strokeBorder(.white.opacity(hovering && on ? 0.35 : 0), lineWidth: 1).padding(-4))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: on ? "checkmark" : "plus")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(on ? .white : .black)
                            .frame(width: 14, height: 14)
                            .background(on ? Color.black : .white, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(on ? 0.9 : 0), lineWidth: 1))
                            .offset(x: 4, y: -4)
                    }
                    .scaleEffect(hovering && enabled ? 1.08 : 1)
                Text(name).font(.system(size: 10.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(on ? 0.95 : 0.55))
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .allowsHitTesting(enabled)
        .onHover { hovering = $0 }
        .help(on ? "A test starts here. Click to remove it." : "Click to start a test here.")
        .animation(.spring(duration: 0.3, bounce: 0.3), value: on)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Dots running along a link in the direction the data is moving. Draws nothing while idle.
struct FlowDots: View {
    var active: Bool
    var towardStart: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { context, size in
                guard active else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate * 0.55
                for i in 0..<6 {
                    var f = (t + Double(i) / 6).truncatingRemainder(dividingBy: 1)
                    if towardStart { f = 1 - f }
                    let dot = CGRect(x: size.width * f - 2, y: size.height / 2 - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.25 + 0.75 * sin(f * .pi))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
