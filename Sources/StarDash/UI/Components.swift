import SwiftUI

enum Palette {
    private static var mono: Bool { Theme.isMono }

    static var accent: Color { mono ? .white : Color(red: 0.30, green: 0.62, blue: 1.0) }
    static var down: Color { mono ? .white : Color(red: 0.30, green: 0.62, blue: 1.0) }
    static var up: Color { mono ? Color(white: 0.58) : Color(red: 0.72, green: 0.52, blue: 1.0) }
    static var good: Color { mono ? .white : Color(red: 0.24, green: 0.80, blue: 0.52) }
    static var warn: Color { Color(red: 1.0, green: 0.66, blue: 0.20) }
    static var bad: Color { mono ? Color(red: 1.0, green: 0.27, blue: 0.23) : Color(red: 1.0, green: 0.36, blue: 0.36) }
    static var power: Color { mono ? Color(white: 0.8) : Color(red: 1.0, green: 0.78, blue: 0.28) }

    static func state(_ s: LinkState) -> Color {
        switch s {
        case .online: return good
        case .degraded: return warn
        case .offline: return bad
        case .unreachable: return .gray
        }
    }

    /// The menu bar dot keeps its colours in every theme: white would vanish on a light menu bar.
    static func nsState(_ s: LinkState) -> NSColor {
        switch s {
        case .online: return NSColor(red: 0.24, green: 0.80, blue: 0.52, alpha: 1)
        case .degraded: return NSColor(red: 1.0, green: 0.66, blue: 0.20, alpha: 1)
        case .offline: return NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1)
        case .unreachable: return .gray
        }
    }

    static func severity(_ s: Int) -> Color {
        switch s {
        case 1: return bad
        case 2: return warn
        default: return .secondary
        }
    }

    static func quality(_ score: Int) -> Color {
        score >= 85 ? good : score >= 65 ? accent : score >= 40 ? warn : bad
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.r(14), style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.primary.opacity(0.13), .primary.opacity(0.03)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            )
    }
}

struct SectionTitle: View {
    var text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
    }
}

struct Row: View {
    var label: String
    var value: String
    var valueColor: Color = .primary

    init(_ label: String, _ value: String?, color: Color = .primary) {
        self.label = label
        self.value = value ?? Fmt.missing
        self.valueColor = value == nil ? .secondary : color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var floor: Double = 0
    var minCeiling: Double = 1

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 1, minCeiling)
            let span = max(top - floor, .leastNonzeroMagnitude)
            var line = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height - size.height * CGFloat((min(max(v, floor), top) - floor) / span)
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var unit: String = ""
    var caption: String
    var color: Color
    var spark: [Double] = []
    var sparkFloor: Double = 0
    var sparkCeiling: Double = 1
    /// When set, the tile shows an hour-long outage strip in place of the sparkline.
    var outages: [LinkEvent]?

    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Group {
                    if let outages {
                        OutageTimeline(events: outages, span: 3600).frame(height: 10).frame(height: 24)
                    } else {
                        Sparkline(values: spark, color: color, floor: sparkFloor, minCeiling: sparkCeiling)
                    }
                }
                .frame(height: 24)
                .padding(.vertical, 2)
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Pillow())
    }
}

struct Banner: View {
    var icon: String
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
    }
}

struct EmptyNote: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
    }
}

/// Splits "21 ms" style strings so the unit can be set smaller than the number.
func splitUnit(_ formatted: String) -> (String, String) {
    guard let space = formatted.lastIndex(of: " ") else {
        if formatted.hasSuffix("%") { return (String(formatted.dropLast()), "%") }
        return (formatted, "")
    }
    return (String(formatted[..<space]), String(formatted[formatted.index(after: space)...]))
}

struct OutageTimeline: View {
    var events: [LinkEvent]
    var span: TimeInterval

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Theme.r(5))
            context.fill(track, with: .color(Palette.good.opacity(0.22)))
            context.clip(to: track)
            let now = Date()
            for event in events {
                let age = now.timeIntervalSince(event.start)
                let x = size.width * CGFloat(1 - age / span)
                let w = max(1.5, size.width * CGFloat(event.duration / span))
                context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Palette.bad))
            }
        }
        .help("Red marks are outages. Right edge is now.")
    }
}
