import SwiftUI

/// The dish page in the main window.
struct DevicePane: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(Overlays.self) private var overlays
    @State private var note: String?

    private var settings: Settings { Settings.shared }

    var body: some View {
        PaneScroll {
            if let dish = store.dish {
                hero(dish)
                actions(dish)
                ComponentBoard(dish: dish)
                DishControls(dish: dish)
                HStack(alignment: .top, spacing: 14) {
                    health(dish)
                    software(dish)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    service(dish)
                    boot(dish)
                }
                .fixedSize(horizontal: false, vertical: true)
                AlertHistory()
            } else {
                PaneTitle("Device")
                EmptyPane(icon: "antenna.radiowaves.left.and.right.slash", title: "No dish data",
                          detail: store.dishError.map { "Nothing useful came back from \(settings.dishHost): \($0)" }
                              ?? "Hardware details appear once the dish answers at \(settings.dishHost).")
            }
        }
    }

    // MARK: Hero

    private func hero(_ dish: DishStatus) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                PaneHero(kicker: "Your dish", title: dish.modelName, subline: subline(dish))

                HStack(alignment: .top, spacing: 34) {
                    HeroStat(label: "Uptime", value: Fmt.duration(dish.uptime.map(Double.init)))
                    let power = splitUnit(Fmt.watts(store.powerW))
                    HeroStat(label: "Power", value: power.0, unit: power.1)
                    HeroStat(label: "Ethernet", value: dish.ethSpeedMbps.map(String.init) ?? Fmt.missing, unit: "Mbps")
                    HeroStat(label: "GPS", value: dish.gpsSats.map(String.init) ?? Fmt.missing, unit: "sats")
                }
                .padding(.top, 28)

                HStack(spacing: 6) {
                    Pill(text: store.state.title, color: Palette.state(store.state))
                    ForEach(dish.alerts, id: \.self) { alert in
                        Pill(text: alert, color: DishStatus.benignAlerts.contains(alert) ? .gray : Palette.warn)
                    }
                }
                .padding(.top, 22)
            }
            Spacer(minLength: 0)
            DishAttitude(alignment: dish.alignment)
                .frame(width: 340, height: 230)
        }
    }

    private func subline(_ dish: DishStatus) -> String {
        var parts: [String] = []
        if let hw = dish.hardwareVersion { parts.append(hw) }
        if let country = dish.countryCode.flatMap({ Locale.current.localizedString(forRegionCode: $0) }) { parts.append(country) }
        if let boots = dish.bootCount { parts.append("booted \(boots) times") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func actions(_ dish: DishStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ActionTile(icon: "arrow.clockwise", title: "Reboot dish", detail: "A few minutes offline", tint: Palette.bad) {
                    overlays.confirm = ConfirmRequest(
                        title: "Reboot the dish?",
                        message: "Everything on this network goes offline for a few minutes.",
                        action: "Reboot"
                    ) {
                        Task {
                            let ok = await store.rebootDish()
                            note = ok ? "Reboot requested. Expect a few minutes offline." : "The dish didn't accept the reboot request."
                        }
                    }
                }
                ActionTile(icon: "person.crop.circle", title: "Starlink account", detail: "Plan, billing and support on starlink.com") {
                    if let url = URL(string: "https://www.starlink.com/account") { NSWorkspace.shared.open(url) }
                }
                ActionTile(icon: "doc.on.doc", title: "Copy details", detail: "Model, firmware and ID for support", tint: Palette.up) {
                    let text = [
                        "Model: \(dish.modelName)",
                        "Hardware: \(dish.hardwareVersion ?? Fmt.missing)",
                        "Firmware: \(dish.softwareVersion ?? Fmt.missing)",
                        "Dish ID: \(dish.id ?? Fmt.missing)",
                    ].joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    note = "Copied to the clipboard."
                }
            }
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).padding(.leading, 4)
            }
        }
    }

    // MARK: Panels

    private func health(_ dish: DishStatus) -> some View {
        let signalGood = dish.snrAboveNoiseFloor && !dish.snrPersistentlyLow
        let serious = dish.alerts.filter { !DishStatus.benignAlerts.contains($0) }
        return Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Health")
                HStack(spacing: 8) {
                    ForEach(dish.readyStates, id: \.0) { name, ready in
                        VStack(spacing: 5) {
                            Image(systemName: ready ? "checkmark" : "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ready ? Palette.good : Palette.bad)
                                .frame(width: 26, height: 26)
                                .background((ready ? Palette.good : Palette.bad).opacity(0.16), in: Circle())
                            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 12)
                Fact("Signal", dish.snrPersistentlyLow ? "Persistently low" : dish.snrAboveNoiseFloor ? "Above noise floor" : "Below noise floor",
                     color: signalGood ? Palette.good : Palette.warn)
                Fact("View of the sky", dish.obstruction.currentlyObstructed ? "Obstructed right now" : "Clear right now",
                     color: dish.obstruction.currentlyObstructed ? Palette.warn : Palette.good)
                Fact("Alerts", serious.isEmpty ? "None" : serious.joined(separator: ", "),
                     color: serious.isEmpty ? Palette.good : Palette.warn)
                if dish.stowRequested { Fact("Stow", "Requested", color: Palette.warn) }
            }
        }
    }

    private func software(_ dish: DishStatus) -> some View {
        let state = dish.softwareUpdateState
        return Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Software and hardware")
                Fact("Firmware", dish.softwareVersion)
                Fact("Updates", Names.softwareUpdate(state),
                     color: state == 6 ? Palette.warn : state == 8 ? Palette.bad : state == 1 ? Palette.good : .white)
                if let progress = dish.softwareUpdateProgress, progress > 0, progress < 1 {
                    ProgressView(value: progress).tint(Theme.control).padding(.bottom, 8)
                }
                Fact("Hardware", dish.hardwareVersion)
                Fact("Dish ID", dish.id)
                Fact("Mount", dish.alignment.hasActuators.map { $0 ? "Motorized" : "Fixed" })
            }
        }
    }

    private func service(_ dish: DishStatus) -> some View {
        Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Service")
                Fact("Class", Names.classOfService(dish.classOfService))
                Fact("Mobility", Names.mobility(dish.mobilityClass))
                Fact("Country", dish.countryCode.map { "\(Names.flag($0)) \(Locale.current.localizedString(forRegionCode: $0) ?? $0)" })
                Fact("Download limit", Names.rateLimit(dish.dlRestricted), color: (dish.dlRestricted ?? 1) > 1 ? Palette.warn : .white)
                Fact("Upload limit", Names.rateLimit(dish.ulRestricted), color: (dish.ulRestricted ?? 1) > 1 ? Palette.warn : .white)
                Text("Plan, billing and account details aren't exposed on the local network.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 6)
            }
        }
    }

    private func boot(_ dish: DishStatus) -> some View {
        let steps = dish.initDurations.sorted { $0.1 < $1.1 }
        let longest = max(1, steps.map(\.1).max() ?? 1)
        return Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Last boot", trailing: steps.isEmpty ? nil : "online in \(longest)s")
                if steps.isEmpty {
                    Text("The dish didn't report its boot timings.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                }
                ForEach(steps, id: \.0) { name, seconds in
                    HStack(spacing: 10) {
                        Text(name).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                            .frame(width: 124, alignment: .leading)
                        GeometryReader { geo in
                            Pillow()
                                .fill(LinearGradient(colors: [Palette.accent.opacity(0.35), Palette.accent], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, geo.size.width * CGFloat(seconds) / CGFloat(longest)), height: 4)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 12)
                        Text("\(seconds)s").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

/// Side view of the dish at its real tilt, with a compass for the direction it faces.
struct DishAttitude: View {
    var alignment: Alignment

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let ground = size.height - 14
                let pivot = CGPoint(x: size.width * 0.40, y: ground - 62)
                let elevation = alignment.elevation ?? 90
                let e = elevation * .pi / 180
                let aim = CGPoint(x: cos(e), y: -sin(e))

                // Ground and mast.
                var base = Path()
                base.move(to: CGPoint(x: 16, y: ground))
                base.addLine(to: CGPoint(x: size.width - 16, y: ground))
                context.stroke(base, with: .color(.white.opacity(0.14)), lineWidth: 1)
                var mast = Path()
                mast.move(to: CGPoint(x: pivot.x, y: ground))
                mast.addLine(to: pivot)
                context.stroke(mast, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round))

                if alignment.elevation != nil {
                    // Elevation arc from the horizon up to the beam.
                    var arc = Path()
                    arc.addArc(center: pivot, radius: 54, startAngle: .zero, endAngle: .degrees(-elevation), clockwise: true)
                    context.stroke(arc, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var horizon = Path()
                    horizon.move(to: pivot)
                    horizon.addLine(to: CGPoint(x: pivot.x + 72, y: pivot.y))
                    context.stroke(horizon, with: .color(.white.opacity(0.14)), lineWidth: 1)
                    let mid = (elevation / 2) * .pi / 180
                    context.draw(
                        Text(String(format: "%.0f°", elevation)).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7)),
                        at: CGPoint(x: pivot.x + cos(mid) * 72, y: pivot.y - sin(mid) * 72)
                    )

                    // Beam.
                    var beam = Path()
                    beam.move(to: pivot)
                    let tip = CGPoint(x: pivot.x + aim.x * 128, y: pivot.y + aim.y * 128)
                    beam.addLine(to: tip)
                    context.stroke(beam, with: .linearGradient(Gradient(colors: [Palette.power, Palette.power.opacity(0)]), startPoint: pivot, endPoint: tip),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }

                // The dish face sits square to the beam.
                var slab = context
                slab.translateBy(x: pivot.x, y: pivot.y)
                slab.rotate(by: .degrees(90 - elevation))
                let face = Path(roundedRect: CGRect(x: -52, y: -5, width: 104, height: 10), cornerRadius: Theme.r(4))
                slab.fill(face, with: .linearGradient(Gradient(colors: [.white, .white.opacity(0.6)]),
                                                      startPoint: CGPoint(x: 0, y: -5), endPoint: CGPoint(x: 0, y: 5)))

                // Compass.
                let c = CGPoint(x: size.width - 58, y: 54)
                let r: CGFloat = 38
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white.opacity(0.16)), lineWidth: 1)
                for (label, angle) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                    let a = angle * .pi / 180
                    context.draw(
                        Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(label == "N" ? 0.8 : 0.35)),
                        at: CGPoint(x: c.x + sin(a) * (r - 9), y: c.y - cos(a) * (r - 9))
                    )
                }
                if let azimuth = alignment.azimuth {
                    let a = azimuth * .pi / 180
                    var needle = Path()
                    needle.move(to: c)
                    needle.addLine(to: CGPoint(x: c.x + sin(a) * (r - 16), y: c.y - cos(a) * (r - 16)))
                    context.stroke(needle, with: .color(Palette.power), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.white))
                }
            }
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var caption: String {
        guard let elevation = alignment.elevation else { return "The dish hasn't reported where it's pointing" }
        var text = String(format: "Tilted %.0f° from flat", 90 - elevation)
        if let azimuth = alignment.azimuth {
            text += String(format: " · facing %@ (%.0f°)", Fmt.compass(azimuth), azimuth < 0 ? azimuth + 360 : azimuth)
        }
        return text
    }
}
