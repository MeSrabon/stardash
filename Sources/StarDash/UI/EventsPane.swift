import SwiftUI

/// Capsule picker with a sliding highlight.
struct ChipPicker<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Side padding of each option; smaller where space is tight.
    var pad: CGFloat = 13
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? .black : .white.opacity(0.6))
                        .padding(.horizontal, pad)
                        .padding(.vertical, pad < 13 ? 5 : 6)
                        .background {
                            if selected {
                                Pillow().fill(.white).matchedGeometryEffect(id: "pick", in: space)
                            }
                        }
                        .contentShape(Pillow())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Pillow())
        .overlay(Pillow().strokeBorder(.white.opacity(0.08)))
    }
}

extension LinkEvent {
    var symbol: String {
        switch reason {
        case 7: return "tree.fill"
        case 2: return "power"
        case 19, 6: return "scope"
        case 8, 9, 5: return "arrow.down.to.line"
        case 4, 18: return "thermometer.high"
        case 13...17, 20: return "wifi.router"
        case 21: return "network"
        case LinkEvent.publicIPChanged: return "globe"
        case LinkEvent.bandSwitch: return "wifi"
        default: return isOutage ? "bolt.slash.fill" : "info.circle"
        }
    }

    var tint: Color {
        if isOutage { return Palette.bad }
        return severity == 2 ? Palette.warn : .white.opacity(0.7)
    }
}

/// Reliability page in the main window.
struct EventsPane: View {
    @Environment(TelemetryStore.self) private var store
    @State private var hours = 6
    @State private var outagesOnly = false
    /// Set by clicking a row under "What caused them"; narrows the log to that cause.
    @State private var cause: String?

    private var rangeLabel: String {
        hours >= 48 ? "\(hours / 24) days" : hours == 1 ? "hour" : "\(hours) hours"
    }

    var body: some View {
        let span = Double(hours) * 3600
        let cutoff = Date().addingTimeInterval(-span)
        let inRange = store.events.filter { $0.start >= cutoff }
        let outages = inRange.filter(\.isOutage)
        let downtime = min(span, outages.reduce(0) { $0 + $1.duration })
        let activeCause = outages.contains { $0.title == cause } ? cause : nil
        let shown = (outagesOnly ? outages : inRange).filter { activeCause == nil || $0.title == activeCause }

        PaneScroll {
            hero(outages: outages, downtime: downtime, span: span)
            timeline(outages: outages, span: span)
            HStack(alignment: .top, spacing: 14) {
                causes(outages: outages, downtime: downtime, active: activeCause).frame(width: 330)
                log(shown, hasOther: inRange.count > outages.count, cause: activeCause)
            }
        }
    }

    // MARK: Hero

    private func hero(outages: [LinkEvent], downtime: Double, span: Double) -> some View {
        let uptime = 1 - downtime / span
        let title = downtime <= 0 ? "100%" : String(format: uptime >= 0.9999 ? "%.3f%%" : "%.2f%%", uptime * 100)
        let longest = outages.map(\.duration).max()

        return HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Kicker("Online over the last \(rangeLabel)")
                Text(title)
                    .font(Theme.display(64))
                    .kerning(-1)
                    .monospacedDigit()
                    .foregroundStyle(uptime >= 0.999 ? .white : uptime >= 0.99 ? Palette.warn : Palette.bad)
                    .contentTransition(.numericText())
                    .padding(.top, 2)
                Text(outages.isEmpty ? "Not a single outage. Nice." : "The link held, apart from the moments below.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 18) {
                ChipPicker(options: [(1, "1h"), (6, "6h"), (24, "24h"), (168, "7d")], selection: $hours)
                HStack(alignment: .top, spacing: 34) {
                    HeroStat(label: "Outages", value: "\(outages.count)")
                    HeroStat(label: "Offline", value: outages.isEmpty ? "0s" : Fmt.duration(downtime))
                    HeroStat(label: "Longest", value: longest.map { Fmt.duration($0) } ?? Fmt.missing)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: Timeline

    private func timeline(outages: [LinkEvent], span: Double) -> some View {
        let now = Date()
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader("Timeline", trailing: "Red marks are outages. History builds while StarDash runs.")
                    .padding(.bottom, -4)
                Canvas { context, size in
                    let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Theme.r(8))
                    context.fill(track, with: .linearGradient(
                        Gradient(colors: [Palette.good.opacity(0.10), Palette.good.opacity(0.28)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                    context.clip(to: track)
                    for i in 1..<4 {
                        let x = size.width * CGFloat(i) / 4
                        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.35)))
                    }
                    for event in outages {
                        let age = now.timeIntervalSince(event.start)
                        let x = size.width * CGFloat(1 - age / span)
                        let w = max(2, size.width * CGFloat(event.duration / span))
                        context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Palette.bad))
                    }
                }
                .frame(height: 54)
                HStack {
                    ForEach(0..<5, id: \.self) { i in
                        Text(i == 4 ? "now" : hours > 24
                             ? now.addingTimeInterval(-span * Double(4 - i) / 4).formatted(.dateTime.weekday(.abbreviated).hour())
                             : now.addingTimeInterval(-span * Double(4 - i) / 4).formatted(date: .omitted, time: .shortened))
                        if i < 4 { Spacer() }
                    }
                }
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: Causes

    private func causes(outages: [LinkEvent], downtime: Double, active: String?) -> some View {
        let grouped = Dictionary(grouping: outages, by: \.title)
            .map { (title: $0.key, symbol: $0.value[0].symbol, count: $0.value.count, time: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.time > $1.time }
        let top = max(1, grouped.first?.time ?? 1)

        return Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("What caused them", trailing: grouped.isEmpty ? nil : "Click one to filter the log")
                if grouped.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal").font(Theme.display(30)).foregroundStyle(Palette.good)
                        Text("Nothing went wrong").font(.system(size: 13, weight: .medium))
                        Text("No outages in this window.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }
                ForEach(grouped.prefix(6), id: \.title) { group in
                    let selected = active == group.title
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { cause = selected ? nil : group.title }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "checkmark" : group.symbol).font(.system(size: 11, weight: selected ? .bold : .regular))
                                    .foregroundStyle(selected ? .white : Palette.bad).frame(width: 16)
                                Text(group.title).font(.system(size: 12.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                                Spacer()
                                Text("\(group.count)× · \(Fmt.duration(group.time))")
                                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                            }
                            GeometryReader { geo in
                                Pillow().fill(.white.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        Pillow().fill(Palette.bad.opacity(0.85))
                                            .frame(width: max(4, geo.size.width * CGFloat(group.time / top)))
                                    }
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 9)
                        .opacity(active == nil || selected ? 1 : 0.4)
                        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Log

    private func log(_ events: [LinkEvent], hasOther: Bool, cause active: String?) -> some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Kicker("Log")
                    Text("\(events.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    if let active {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { cause = nil }
                        } label: {
                            HStack(spacing: 6) {
                                Text(active)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white, in: Pillow())
                        }
                        .buttonStyle(.plain)
                    }
                    // Only offered when there is something besides outages to hide.
                    if hasOther {
                        ChipPicker(options: [(false, "Everything"), (true, "Outages")], selection: $outagesOnly)
                    } else if active == nil, !events.isEmpty {
                        Text("All of these are outages").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(minHeight: 30)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                if events.isEmpty {
                    Text("Nothing logged in this window.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                }
                ForEach(events.prefix(150)) { event in
                    EventLine(event: event)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct EventLine: View {
    var event: LinkEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: event.symbol, tint: event.tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(Fmt.dayClock.string(from: event.start)) · \(event.detail ?? "\(event.source) · \(Names.severity(event.severity))")")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text(event.duration > 0 ? Fmt.duration(event.duration) : (event.isOutage ? "ongoing" : ""))
                .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(event.isOutage && event.duration >= 10 ? Palette.bad : .white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.white.opacity(hovering ? 0.05 : 0))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 58) }
        .onHover { hovering = $0 }
    }
}
