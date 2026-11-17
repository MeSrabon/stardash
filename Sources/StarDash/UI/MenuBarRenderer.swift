import AppKit

/// Draws the menu bar readout as one template image so macOS tints it for any wallpaper.
@MainActor
enum MenuBarRenderer {
    static let height: CGFloat = 22

    @MainActor private enum Segment {
        case text(String)
        case stacked(String, String)
        case sparkline([Float])
        case icon(NSImage)

        var width: CGFloat {
            switch self {
            case .text(let s): return ceil(NSAttributedString(string: s, attributes: MenuBarRenderer.textAttributes).size().width)
            case .stacked(let a, let b):
                let wa = NSAttributedString(string: a, attributes: MenuBarRenderer.smallAttributes).size().width
                let wb = NSAttributedString(string: b, attributes: MenuBarRenderer.smallAttributes).size().width
                return ceil(max(wa, wb))
            case .sparkline: return 34
            case .icon(let image): return image.size.width
            }
        }
    }

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.black,
    ]

    private static let smallAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]

    static func image(store: TelemetryStore, settings: Settings, leadingInset: CGFloat) -> NSImage {
        var segments: [Segment] = []
        let state = store.state

        let symbolName: String
        switch state {
        case .online, .degraded: symbolName = "antenna.radiowaves.left.and.right"
        case .offline, .unreachable: symbolName = "antenna.radiowaves.left.and.right.slash"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Starlink")?
            .withSymbolConfiguration(config) {
            segments.append(.icon(symbol))
        }

        // When something's wrong, say what. A dish that's down has no numbers worth showing.
        switch state {
        case .online: break
        case .degraded(let why), .offline(let why): segments.append(.text(why))
        case .unreachable: segments.append(.text("No dish"))
        }

        if let dish = store.dish, store.dishError == nil, state.isUp {
            for item in settings.menuBarItems {
                switch item {
                case .latency:
                    segments.append(.text(state.isUp ? Fmt.ms(dish.latencyMs) : Fmt.missing))
                case .pingSuccess:
                    segments.append(.text(Fmt.percent(store.stats(60).pingSuccess)))
                case .throughput:
                    segments.append(.stacked(
                        "↑ " + Fmt.rate(dish.upBps, bytes: settings.useBytes),
                        "↓ " + Fmt.rate(dish.downBps, bytes: settings.useBytes)
                    ))
                case .power:
                    segments.append(.text(Fmt.watts(store.powerW)))
                case .obstruction:
                    segments.append(.text(Fmt.percent(dish.obstruction.fraction)))
                case .events:
                    let count = store.outages(since: 3600).count
                    segments.append(.text("\(count) " + (count == 1 ? "outage" : "outages")))
                case .sparkline:
                    segments.append(.sparkline(store.window(90).map { $0.drop >= 1 ? 0 : $0.latency }))
                }
            }
        }

        let gap: CGFloat = 6
        let width = leadingInset + segments.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, segments.count - 1))
        let size = NSSize(width: ceil(width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x = leadingInset
            for segment in segments {
                switch segment {
                case .icon(let symbol):
                    let rect = NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
                    symbol.draw(in: rect)
                case .text(let s):
                    let str = NSAttributedString(string: s, attributes: textAttributes)
                    str.draw(at: NSPoint(x: x, y: (height - str.size().height) / 2))
                case .stacked(let top, let bottom):
                    let w = segment.width
                    let a = NSAttributedString(string: top, attributes: smallAttributes)
                    let b = NSAttributedString(string: bottom, attributes: smallAttributes)
                    a.draw(at: NSPoint(x: x + w - a.size().width, y: height / 2 - 0.5))
                    b.draw(at: NSPoint(x: x + w - b.size().width, y: height / 2 - b.size().height + 0.5))
                case .sparkline(let values):
                    drawSparkline(values, in: NSRect(x: x, y: 5, width: segment.width, height: height - 10))
                }
                x += segment.width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawSparkline(_ values: [Float], in rect: NSRect) {
        guard values.count > 1 else { return }
        let top = max(values.max() ?? 1, 60)
        let path = NSBezierPath()
        for (i, v) in values.enumerated() {
            let px = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let py = rect.minY + rect.height * CGFloat(min(v, top) / top)
            if i == 0 { path.move(to: NSPoint(x: px, y: py)) } else { path.line(to: NSPoint(x: px, y: py)) }
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }
}
