import SwiftUI

struct SkyTab: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.wideLayout) private var wide
    @Environment(Overlays.self) private var overlays
    @State private var resetNote: (text: String, failed: Bool)?
    var showMap = true

    var body: some View {
        let dish = store.dish
        let o = dish?.obstruction

        VStack(spacing: 10) {
            if showMap {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Obstruction map", trailing: store.map.map { "\(Fmt.percent($0.coverage, digits: 0)) of sky mapped" })
                        if let map = store.map {
                            ObstructionMapView(map: map, alignment: dish?.alignment)
                                .frame(height: wide ? 380 : 250)
                            HStack(spacing: 14) {
                                legendDot(Palette.accent, "Clear")
                                legendDot(Palette.bad, "Obstructed")
                                legendDot(.primary.opacity(0.12), "Not sampled yet")
                                Spacer()
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        } else {
                            EmptyNote(icon: "scope", title: "No map yet",
                                      detail: "The dish builds its sky map over the first hours after boot.")
                        }
                    }
                }
            }

            Card {
                VStack(spacing: 6) {
                    SectionTitle("Obstructions")
                    Row("Sky obstructed", Fmt.percent(o?.fraction, digits: 2),
                        color: (o?.fraction ?? 0) < 0.01 ? Palette.good : Palette.warn)
                    Row("Time obstructed", Fmt.percent(o?.timeObstructed, digits: 2))
                    Row("Right now", o.map { $0.currentlyObstructed ? "Obstructed" : "Clear" },
                        color: o?.currentlyObstructed == true ? Palette.bad : Palette.good)
                    if let interval = o?.avgProlongedInterval, interval.isFinite, interval > 0 {
                        Row("Typical interruption", "every \(Fmt.duration(interval)), for \(Fmt.duration(o?.avgProlongedDuration))")
                    }
                    Row("Measured over", o?.validSeconds.map { Fmt.duration($0) })
                    if dish != nil { resetRow }
                }
            }

            if let a = dish?.alignment {
                Card {
                    VStack(spacing: 6) {
                        SectionTitle("Alignment")
                        AlignmentDials(alignment: a).padding(.vertical, 6)
                        if let hint = alignmentHint(a) {
                            HStack(spacing: 8) {
                                Image(systemName: hint.ok ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                    .foregroundStyle(hint.ok ? Palette.good : Palette.warn)
                                Text(hint.text).font(.system(size: 12, weight: .medium))
                                Spacer()
                            }
                            .padding(.bottom, 2)
                        }
                        Row("Pointing", a.azimuth.map { "\(Fmt.degrees($0)) \(Fmt.compass($0))" })
                        Row("Ideal pointing", a.desiredAzimuth.map { "\(Fmt.degrees($0)) \(Fmt.compass($0))" })
                        Row("Elevation", Fmt.degrees(a.elevation))
                        Row("Ideal elevation", Fmt.degrees(a.desiredElevation))
                        Row("Tilt", Fmt.degrees(a.tilt))
                        Row("Attitude estimate", a.converged.map { $0 ? "Converged" : "Still determining" },
                            color: a.converged == true ? .primary : Palette.warn)
                        Row("Uncertainty", a.uncertainty.map { "±" + Fmt.degrees($0, digits: 2) })
                        Row("GPS", dish?.gpsValid.map { $0 ? "\(dish?.gpsSats ?? 0) satellites" : "No fix" },
                            color: dish?.gpsValid == false ? Palette.warn : .primary)
                    }
                }
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: Theme.r(2)).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }

    private func alignmentHint(_ a: Alignment) -> (text: String, ok: Bool)? {
        guard let az = a.azimuthError, let el = a.elevationError else { return nil }
        if a.converged == false { return ("Dish is still working out where it points", false) }
        if abs(az) < 10, abs(el) < 10 { return ("Well aligned, no adjustment needed", true) }
        var steps: [String] = []
        if abs(az) >= 10 {
            steps.append(String(format: "rotate %.0f° %@", abs(az), az > 0 ? "clockwise" : "counter-clockwise"))
        }
        if abs(el) >= 10 {
            steps.append(String(format: "tilt %.0f° %@", abs(el), el > 0 ? "up" : "down"))
        }
        let text = steps.joined(separator: ", ")
        return (text.prefix(1).uppercased() + text.dropFirst() + " for the ideal view", false)
    }

    /// After moving the dish or clearing a tree, the old map is stale. Same confirm as on the Device page.
    private var resetRow: some View {
        HStack(spacing: 8) {
            if let note = resetNote {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(note.failed ? Palette.bad : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Reset map…") {
                overlays.confirm = ConfirmRequest(
                    title: "Reset the obstruction map?",
                    message: "The dish forgets what it has learned about its view of the sky and starts again, which takes several hours. Worth doing after moving the dish or clearing an obstruction. The time-lapse starts over too.",
                    action: "Reset map"
                ) {
                    Task {
                        let ok = await store.clearObstructionMap()
                        resetNote = ok ? ("Map reset. It rebuilds over the next hours.", false) : ("That didn't go through.", true)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

struct ObstructionMapView: View {
    var map: ObstructionMap
    var alignment: Alignment?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 26
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().fill(.primary.opacity(0.05)).frame(width: side, height: side)
                if let image = Self.render(map) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: side, height: side)
                        .clipShape(Circle())
                }
                ForEach([1.0 / 3, 2.0 / 3, 1.0], id: \.self) { f in
                    Circle().stroke(.primary.opacity(0.12), lineWidth: 0.75).frame(width: side * f, height: side * f)
                }
                Path { p in
                    p.move(to: CGPoint(x: center.x - side / 2, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + side / 2, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - side / 2))
                    p.addLine(to: CGPoint(x: center.x, y: center.y + side / 2))
                }
                .stroke(.primary.opacity(0.08), lineWidth: 0.75)

                ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, label in
                    let angle = Double(i) * .pi / 2
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(label == "N" ? Palette.bad : .secondary)
                        .position(x: center.x + sin(angle) * (side / 2 + 9), y: center.y - cos(angle) * (side / 2 + 9))
                }

                if let az = alignment?.azimuth, let el = alignment?.elevation {
                    let r = min(1, (90 - el) / map.maxTheta) * (side / 2)
                    let rad = az * .pi / 180
                    Circle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(Circle().fill(Palette.power))
                        .frame(width: 9, height: 9)
                        .position(x: center.x + sin(rad) * r, y: center.y - cos(rad) * r)
                        .help("Where the dish is pointing")
                }
            }
        }
    }

    /// One pixel per sky cell: red for blocked, blue for clear, transparent where the dish hasn't looked.
    static func render(_ map: ObstructionMap, dome: Bool = false) -> CGImage? {
        let w = map.cols, h = map.rows
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = map.snr[i]
            guard v >= 0 else { continue }
            let clear = Double(min(1, v))
            let r = 1.0 + (0.30 - 1.0) * clear
            let g = 0.36 + (0.62 - 0.36) * clear
            let b = 0.36 + (1.0 - 0.36) * clear
            // On the 3D dome clear sky is see-through so the dish stays visible; blocked cells stay solid.
            let alpha = dome ? 0.9 - 0.5 * clear : 1.0
            pixels[i * 4] = UInt8(r * alpha * 255)
            pixels[i * 4 + 1] = UInt8(g * alpha * 255)
            pixels[i * 4 + 2] = UInt8(b * alpha * 255)
            pixels[i * 4 + 3] = UInt8(alpha * 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
