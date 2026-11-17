import SwiftUI

/// Live satellites to draw on top of a sky view.
struct SkyOverlay {
    var satellites: [VisibleSatellite] = []
    var ahead: [Int: SkyPosition] = [:]
    /// The satellite to single out.
    var best: Int?

    /// Draws each satellite as a dot with a short tail pointing the way it's travelling.
    /// `project` turns a direction into a point on the view, or nil when it's off the chart.
    func draw(in context: inout GraphicsContext, compact: Bool, width: CGFloat = .infinity, project: (Double, Double) -> CGPoint?) {
        var highlight: (CGPoint, String)?
        for sat in satellites {
            guard let p = project(sat.azimuth, sat.elevation) else { continue }
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            // The small dashboard chart only has room for the satellites that could be serving.
            if compact, !inRange { continue }
            let ink = Color.white.opacity(inRange ? 1 : 0.4)
            if let next = ahead[sat.id], let q = project(next.azimuth, next.elevation) {
                let dx = q.x - p.x, dy = q.y - p.y
                let length = (dx * dx + dy * dy).squareRoot()
                // A long jump means the track wrapped around the edge of an unrolled view.
                if length > 0.5, length < 80 {
                    var tail = Path()
                    tail.move(to: p)
                    let reach: CGFloat = compact ? 6 : 9
                    tail.addLine(to: CGPoint(x: p.x + dx / length * reach, y: p.y + dy / length * reach))
                    context.stroke(tail, with: .color(ink.opacity(0.6)), lineWidth: 1)
                }
            }
            let size: CGFloat = compact ? 3.5 : inRange ? 5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
            context.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 2)
            context.fill(dot, with: .color(ink))
            if sat.id == best { highlight = (p, sat.name) }
        }
        if let (p, name) = highlight {
            let ring: CGFloat = compact ? 6 : 8
            context.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)), with: .color(.white), lineWidth: 1.5)
            let label = Text(name).font(.system(size: compact ? 8.5 : 10, weight: .semibold)).foregroundColor(.white)
            let resolved = context.resolve(label)
            let box = resolved.measure(in: CGSize(width: 200, height: 20))
            // Sits to the right of the ring, or to the left when it would run off the edge.
            let fits = p.x + ring + 6 + box.width + 4 <= width
            let origin = CGPoint(x: fits ? p.x + ring + 6 : p.x - ring - 6 - box.width, y: p.y - box.height / 2)
            context.fill(Path(roundedRect: CGRect(x: origin.x - 4, y: origin.y - 2, width: box.width + 8, height: box.height + 4), cornerRadius: Theme.r(4)),
                         with: .color(.black.opacity(0.75)))
            context.draw(resolved, at: origin, anchor: .topLeading)
        }
    }
}

extension SkyOverlay {
    /// The satellite drawn closest to a point, if one is within reach of the pointer.
    func nearest(to point: CGPoint, compact: Bool = false, within reach: CGFloat = 11,
                 project: (Double, Double) -> CGPoint?) -> (satellite: VisibleSatellite, at: CGPoint)? {
        var found: (VisibleSatellite, CGPoint)?
        var closest = reach
        for sat in satellites {
            if compact, sat.elevation < SkyWatch.serviceElevation { continue }
            guard let p = project(sat.azimuth, sat.elevation) else { continue }
            let d = ((p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y)).squareRoot()
            if d < closest { closest = d; found = (sat, p) }
        }
        return found.map { (satellite: $0.0, at: $0.1) }
    }
}

/// Name tag for the satellite under the pointer.
struct SatelliteReadout: View {
    var satellite: VisibleSatellite
    var compact = false

    var body: some View {
        let inRange = satellite.elevation >= SkyWatch.serviceElevation
        HStack(spacing: 7) {
            Text(satellite.name).fontWeight(.semibold)
            if compact {
                Text(String(format: "%.0f° up", satellite.elevation)).foregroundStyle(.white.opacity(0.6))
            } else {
                Text(String(format: "%.0f° up · %@ %.0f° · %.0f km away%@", satellite.elevation, Fmt.compass(satellite.azimuth),
                            satellite.azimuth, satellite.rangeKm, inRange ? "" : " · too low to serve"))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: compact ? 9.5 : 12))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, compact ? 7 : 12)
        .padding(.vertical, compact ? 4 : 7)
        .background(.black.opacity(0.85), in: Pillow())
        .overlay(Pillow().strokeBorder(.white.opacity(0.25)))
        .fixedSize()
    }
}

/// Lets the small dashboard chart name whichever satellite the pointer is on.
struct CompactSatelliteHover: View {
    var sky: SkyOverlay
    var maxTheta: Double
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            // Same geometry as the compact radar it sits on.
            let radius = (min(geo.size.width, geo.size.height) - 6) / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let hit = pointer.flatMap { p in
                sky.nearest(to: p, compact: true) { azimuth, elevation in
                    let f = (90 - elevation) / maxTheta
                    guard f <= 1 else { return nil }
                    let a = azimuth * .pi / 180
                    return CGPoint(x: c.x + sin(a) * radius * CGFloat(f), y: c.y - cos(a) * radius * CGFloat(f))
                }
            }
            ZStack {
                if let hit {
                    Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 13, height: 13).position(hit.at)
                    SatelliteReadout(satellite: hit.satellite, compact: true)
                        .position(x: min(max(hit.at.x, 70), geo.size.width - 70), y: hit.at.y < 26 ? hit.at.y + 18 : hit.at.y - 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): pointer = p
                case .ended: pointer = nil
                }
            }
        }
    }
}

/// Play button and scrubber for the frames of the sky map StarDash has recorded.
struct TimeLapseBar: View {
    var frames: [MapFrame]
    @Binding var frame: Int?
    @Binding var playing: Bool

    var body: some View {
        let last = frames.count - 1
        let index = min(frame ?? last, last)
        HStack(spacing: 12) {
            Button {
                if Driver.directory != nil { print("play pressed") }
                if playing { playing = false } else {
                    if frame == nil || index >= last { frame = 0 }
                    playing = true
                }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.1), in: Pillow())
                    .overlay(Pillow().strokeBorder(.white.opacity(0.2)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("Play how the sky map filled in")

            TrackSlider(value: Binding(
                get: { last > 0 ? Double(index) / Double(last) : 1 },
                set: { value in
                    playing = false
                    let i = Int((value * Double(last)).rounded())
                    frame = i >= last ? nil : i
                }
            ))

            VStack(alignment: .trailing, spacing: 1) {
                Text(frame == nil ? "Live" : Fmt.dayClock.string(from: frames[index].date))
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Map time-lapse · \(frames.count) frames since \(Fmt.dayClock.string(from: frames[0].date))")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .monospacedDigit()
            .frame(width: 270, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(12), style: .continuous).strokeBorder(.white.opacity(0.12)))
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(max(60, 6000 / max(1, frames.count))))
                guard !Task.isCancelled else { return }
                let next = (frame ?? last) + 1
                if next >= last {
                    frame = nil
                    playing = false
                    return
                }
                frame = next
            }
        }
    }
}

/// A slider drawn to match the theme. Value runs from 0 to 1.
/// Built on plain mouse handling, which tracks a press and drag more dependably than a gesture does.
struct TrackSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> TrackSliderView {
        let view = TrackSliderView()
        view.onChange = { value = $0 }
        return view
    }

    func updateNSView(_ view: TrackSliderView, context: Context) {
        view.onChange = { value = $0 }
        view.square = Theme.isMono
        if abs(view.value - value) > 0.0001 {
            view.value = value
            view.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 22)
    }
}

final class TrackSliderView: NSView {
    var value = 1.0
    var square = false
    var onChange: (Double) -> Void = { _ in }
    private let knob: CGFloat = 12

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let x = knob / 2 + (bounds.width - knob) * CGFloat(min(1, max(0, value)))
        let mid = bounds.midY
        let radius: CGFloat = square ? 1 : 1.5
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: mid - 1.5, width: bounds.width, height: 3), xRadius: radius, yRadius: radius).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: mid - 1.5, width: x, height: 3), xRadius: radius, yRadius: radius).fill()
        let corner: CGFloat = square ? 2 : knob / 2
        NSBezierPath(roundedRect: NSRect(x: x - knob / 2, y: mid - knob / 2, width: knob, height: knob), xRadius: corner, yRadius: corner).fill()
    }

    private func track(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        value = min(1, max(0, Double((x - knob / 2) / max(1, bounds.width - knob))))
        needsDisplay = true
        onChange(value)
    }

    override func mouseDown(with event: NSEvent) {
        if Driver.directory != nil { print("slider mouseDown, frame in window \(convert(bounds, to: nil).integral)") }
        track(event)
    }
    override func mouseDragged(with event: NSEvent) { track(event) }
}
