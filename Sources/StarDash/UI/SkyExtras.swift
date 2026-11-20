import AppKit
import SwiftUI

/// A satellite drawn as a little craft: a square body with a solar wing either side.
enum SatelliteGlyph {
    /// The glyph `width` wide, centred on `center`, wings along `angle` (radians, 0 = wings left and right).
    static func path(at center: CGPoint, width: CGFloat, angle: CGFloat = 0) -> Path {
        var unit = Path()
        unit.addRoundedRect(in: CGRect(x: -0.16, y: -0.16, width: 0.32, height: 0.32), cornerSize: CGSize(width: 0.07, height: 0.07))
        for side: CGFloat in [-1, 1] {
            unit.addRect(CGRect(x: side < 0 ? -0.23 : 0.13, y: -0.04, width: 0.10, height: 0.08))
            unit.addRoundedRect(in: CGRect(x: side < 0 ? -0.5 : 0.23, y: -0.19, width: 0.27, height: 0.38),
                                cornerSize: CGSize(width: 0.04, height: 0.04))
        }
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).scaledBy(x: width, y: width)
        return unit.applying(transform)
    }

    /// The glyph lit like a satellite catching the sun: a bright body and softer wings, with no outline.
    static func glint(color: NSColor, side: CGFloat = 128) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: side / 2, y: side / 2)
            let w = side * 0.9
            // Wings first, a touch dimmer, then the body on top.
            cg.addPath(path(at: c, width: w).cgPath)
            cg.setFillColor(color.withAlphaComponent(0.7).cgColor)
            cg.fillPath()
            cg.addPath(Path(roundedRect: CGRect(x: c.x - w * 0.16, y: c.y - w * 0.16, width: w * 0.32, height: w * 0.32), cornerRadius: w * 0.07).cgPath)
            cg.setFillColor(color.cgColor)
            cg.fillPath()
            return true
        }
    }

    /// A square image of the glyph, for textures in the 3D views.
    static func image(color: NSColor, side: CGFloat = 96) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let shape = path(at: CGPoint(x: side / 2, y: side / 2), width: side * 0.86).cgPath
            cg.addPath(shape)
            cg.setStrokeColor(NSColor(white: 0, alpha: 0.7).cgColor)
            cg.setLineWidth(side * 0.07)
            cg.setLineJoin(.round)
            cg.strokePath()
            cg.addPath(shape)
            cg.setFillColor(color.cgColor)
            cg.fillPath()
            return true
        }
    }
}

/// Live satellites to draw on top of a sky view.
struct SkyOverlay {
    var satellites: [VisibleSatellite] = []
    var ahead: [Int: SkyPosition] = [:]
    /// The satellite to single out.
    var best: Int?

    /// Draws each satellite as a small craft turned across its path, with a fading trail behind it.
    /// `project` turns a direction into a point on the view, or nil when it's off the chart.
    func draw(in context: inout GraphicsContext, compact: Bool, width: CGFloat = .infinity, project: (Double, Double) -> CGPoint?) {
        var highlight: (CGPoint, CGFloat, String)?
        for sat in satellites {
            guard let p = project(sat.azimuth, sat.elevation) else { continue }
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            // The small dashboard chart only has room for the satellites that could be serving.
            if compact, !inRange { continue }
            let ink = Color.white.opacity(inRange ? 1 : 0.4)
            // At popover size 80 craft turn into a pile, so the others are plain dots there.
            if compact, sat.id != best {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)), with: .color(ink.opacity(0.75)))
                continue
            }
            var heading: CGFloat = -.pi / 4
            if let next = ahead[sat.id], let q = project(next.azimuth, next.elevation) {
                let dx = q.x - p.x, dy = q.y - p.y
                let length = (dx * dx + dy * dy).squareRoot()
                // A long jump means the track wrapped around the edge of an unrolled view.
                if length > 0.5, length < 80 {
                    heading = atan2(dy, dx)
                    let reach: CGFloat = compact ? 7 : 14
                    let end = CGPoint(x: p.x - dx / length * reach, y: p.y - dy / length * reach)
                    var trail = Path()
                    trail.move(to: end)
                    trail.addLine(to: p)
                    context.stroke(trail, with: .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.5)]), startPoint: end, endPoint: p),
                                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            if sat.id == best {
                highlight = (p, heading, sat.name)
                continue
            }
            let size: CGFloat = compact ? 9 : inRange ? 14 : 10
            let craft = SatelliteGlyph.path(at: p, width: size, angle: heading + .pi / 2)
            context.stroke(craft, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            context.fill(craft, with: .color(ink))
        }
        guard let (p, heading, name) = highlight else { return }

        // The one the dish is most likely talking to: in its own colour, with a glow and a ring.
        let glow: CGFloat = compact ? 13 : 22
        context.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [Palette.link.opacity(0.5), Palette.link.opacity(0.12), Palette.link.opacity(0)]),
                                           center: p, startRadius: 0, endRadius: glow))
        let ring: CGFloat = compact ? 9 : 14
        context.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                       with: .color(Palette.link), lineWidth: 1.5)
        let craft = SatelliteGlyph.path(at: p, width: compact ? 12 : 19, angle: heading + .pi / 2)
        context.stroke(craft, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        context.fill(craft, with: .color(Palette.link))
        // The popover names it in the text beside the chart.
        if compact { return }

        let label = Text(name).font(.system(size: compact ? 8.5 : 10, weight: .semibold)).foregroundColor(.white)
        let resolved = context.resolve(label)
        let box = resolved.measure(in: CGSize(width: 200, height: 20))
        // Sits to the right of the ring, or to the left when it would run off the edge.
        let fits = p.x + ring + 7 + box.width + 4 <= width
        let origin = CGPoint(x: fits ? p.x + ring + 7 : p.x - ring - 7 - box.width, y: p.y - box.height / 2)
        let pill = Path(roundedRect: CGRect(x: origin.x - 5, y: origin.y - 2, width: box.width + 10, height: box.height + 4), cornerRadius: Theme.r(5))
        context.fill(pill, with: .color(.black.opacity(0.8)))
        context.stroke(pill, with: .color(Palette.link.opacity(0.6)), lineWidth: 1)
        context.draw(resolved, at: origin, anchor: .topLeading)
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
