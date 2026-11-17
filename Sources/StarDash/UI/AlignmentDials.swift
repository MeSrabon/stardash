import SwiftUI

/// Two dials for aiming the dish: which way it faces and how far it's tilted.
/// The shaded zone on each is where the dish says it should be, give or take the tolerance.
struct AlignmentDials: View {
    var alignment: Alignment
    /// Degrees either side of ideal that count as aligned.
    static let tolerance = 10.0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dial(title: "Direction", error: alignment.azimuthError,
                 reading: alignment.azimuth.map { String(format: "%.0f° %@", $0 < 0 ? $0 + 360 : $0, Fmt.compass($0)) },
                 fix: { $0 > 0 ? "Turn clockwise" : "Turn counter-clockwise" }) {
                CompassDial(current: alignment.azimuth, ideal: alignment.desiredAzimuth)
            }
            dial(title: "Tilt", error: alignment.elevationError,
                 reading: alignment.elevation.map { String(format: "%.0f° up", $0) },
                 fix: { $0 > 0 ? "Tilt up" : "Tilt down" }) {
                TiltDial(current: alignment.elevation, ideal: alignment.desiredElevation)
            }
        }
    }

    private func dial(title: String, error: Double?, reading: String?, fix: (Double) -> String,
                      @ViewBuilder face: () -> some View) -> some View {
        let ok = error.map { abs($0) <= Self.tolerance }
        return VStack(spacing: 6) {
            Kicker(title)
            face().frame(height: 104)
            Text(reading ?? Fmt.missing).font(Theme.number(17)).monospacedDigit()
            Group {
                if let error, let ok {
                    Text(ok ? String(format: "On target, %.0f° off", abs(error)) : String(format: "%@ %.0f°", fix(error), abs(error)))
                        .foregroundStyle(ok ? Color.white.opacity(0.5) : Palette.warn)
                } else {
                    Text("No ideal reported").foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private func point(_ center: CGPoint, _ radius: CGFloat, compass degrees: Double) -> CGPoint {
    let a = degrees * .pi / 180
    return CGPoint(x: center.x + sin(a) * radius, y: center.y - cos(a) * radius)
}

/// Seen from above: north at the top, a needle for where the dish faces, a zone for where it should.
private struct CompassDial: View {
    var current: Double?
    var ideal: Double?

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 12
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(.white.opacity(0.18)), lineWidth: 1)
            for degrees in stride(from: 0.0, to: 360, by: 30) {
                var tick = Path()
                tick.move(to: point(c, r, compass: degrees))
                tick.addLine(to: point(c, r - (degrees.truncatingRemainder(dividingBy: 90) == 0 ? 6 : 3), compass: degrees))
                context.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            for (label, degrees) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                context.draw(Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(label == "N" ? 0.9 : 0.4)),
                             at: point(c, r + 8, compass: degrees))
            }
            if let ideal {
                let t = AlignmentDials.tolerance
                var zone = Path()
                // Canvas angles run clockwise from the x axis; compass angles run clockwise from north.
                zone.addArc(center: c, radius: r - 5, startAngle: .degrees(ideal - t - 90), endAngle: .degrees(ideal + t - 90), clockwise: false)
                context.stroke(zone, with: .color(Palette.good.opacity(0.4)), style: StrokeStyle(lineWidth: 9))
                var mark = Path()
                mark.move(to: point(c, r + 1, compass: ideal))
                mark.addLine(to: point(c, r - 11, compass: ideal))
                context.stroke(mark, with: .color(Palette.good), lineWidth: 1.5)
            }
            if let current {
                let ok = ideal.map { abs(Alignment(azimuth: current, desiredAzimuth: $0).azimuthError ?? 0) <= AlignmentDials.tolerance } ?? true
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: point(c, r - 14, compass: current))
                context.stroke(needle, with: .color(ok ? .white : Palette.warn), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }
}

/// Seen from the side: flat ground at the bottom, straight up at the top.
private struct TiltDial: View {
    var current: Double?
    var ideal: Double?

    var body: some View {
        Canvas { context, size in
            let r = min(size.width - 30, size.height - 22)
            let c = CGPoint(x: (size.width - r) / 2 + 2, y: size.height - 12)
            func at(_ elevation: Double, _ radius: CGFloat) -> CGPoint {
                let a = elevation * .pi / 180
                return CGPoint(x: c.x + cos(a) * radius, y: c.y - sin(a) * radius)
            }
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(-90), clockwise: true)
            context.stroke(arc, with: .color(.white.opacity(0.18)), lineWidth: 1)
            var ground = Path()
            ground.move(to: c)
            ground.addLine(to: CGPoint(x: c.x + r + 6, y: c.y))
            context.stroke(ground, with: .color(.white.opacity(0.18)), lineWidth: 1)
            for elevation in stride(from: 0.0, through: 90, by: 15) {
                var tick = Path()
                tick.move(to: at(elevation, r))
                tick.addLine(to: at(elevation, r - (elevation.truncatingRemainder(dividingBy: 45) == 0 ? 6 : 3)))
                context.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            context.draw(Text("0°").font(.system(size: 9)).foregroundColor(.white.opacity(0.4)), at: CGPoint(x: c.x + r + 4, y: c.y + 8))
            context.draw(Text("90°").font(.system(size: 9)).foregroundColor(.white.opacity(0.4)), at: CGPoint(x: c.x, y: c.y - r - 7))
            if let ideal {
                let t = AlignmentDials.tolerance
                var zone = Path()
                zone.addArc(center: c, radius: r - 5, startAngle: .degrees(-max(0, ideal - t)), endAngle: .degrees(-min(90, ideal + t)), clockwise: true)
                context.stroke(zone, with: .color(Palette.good.opacity(0.4)), style: StrokeStyle(lineWidth: 9))
                var mark = Path()
                mark.move(to: at(ideal, r + 1))
                mark.addLine(to: at(ideal, r - 11))
                context.stroke(mark, with: .color(Palette.good), lineWidth: 1.5)
            }
            if let current {
                let ok = ideal.map { abs($0 - current) <= AlignmentDials.tolerance } ?? true
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: at(min(90, max(0, current)), r - 14))
                context.stroke(needle, with: .color(ok ? .white : Palette.warn), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
        }
    }
}
