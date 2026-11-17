import SwiftUI

/// One part of the system and whether it's healthy.
private struct Component: Identifiable {
    enum Level { case ok, warn, bad, idle }
    var id: String { name }
    var name: String
    var icon: String
    var status: String
    var level: Level = .ok

    var color: Color {
        switch level {
        case .ok: return Palette.good
        case .warn: return Palette.warn
        case .bad: return Palette.bad
        case .idle: return .white.opacity(0.35)
        }
    }
}

/// Every part of the dish at a glance, worked out from its status flags and alerts.
struct ComponentBoard: View {
    @Environment(TelemetryStore.self) private var store
    var dish: DishStatus

    var body: some View {
        let parts = components
        let trouble = parts.filter { $0.level == .warn || $0.level == .bad }.count
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Components", trailing: trouble == 0 ? "All working" : "\(trouble) need\(trouble == 1 ? "s" : "") attention")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(parts) { part in
                        HStack(spacing: 10) {
                            Image(systemName: part.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(part.level == .idle ? 0.4 : 0.85))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.name).font(.system(size: 12, weight: .medium))
                                Text(part.status).font(.system(size: 10.5)).foregroundStyle(part.level == .ok || part.level == .idle ? .white.opacity(0.45) : part.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Circle().fill(part.color).frame(width: 7, height: 7)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous)
                            .strokeBorder(part.level == .warn || part.level == .bad ? part.color.opacity(0.5) : .white.opacity(0.08)))
                    }
                }
            }
        }
    }

    private var components: [Component] {
        let alerts = Set(dish.alerts)
        func has(_ names: String...) -> String? { names.first(where: alerts.contains) }
        var list: [Component] = []

        let rf = dish.readyStates.first { $0.0 == "RF" }?.1 ?? true
        list.append(Component(name: "Antenna", icon: "antenna.radiowaves.left.and.right",
                              status: rf ? "Transmitting" : "Not ready", level: rf ? .ok : .bad))

        if dish.snrPersistentlyLow || alerts.contains("Signal lower than predicted") {
            list.append(Component(name: "Signal", icon: "waveform", status: "Lower than expected", level: .warn))
        } else {
            list.append(Component(name: "Signal", icon: "waveform", status: dish.snrAboveNoiseFloor ? "Above noise floor" : "Below noise floor",
                                  level: dish.snrAboveNoiseFloor ? .ok : .warn))
        }

        let blocked = dish.obstruction.currentlyObstructed
        list.append(Component(name: "Sky view", icon: "tree",
                              status: blocked ? "Obstructed right now" : "\(Fmt.percent(dish.obstruction.fraction, digits: 2)) obstructed",
                              level: blocked ? .warn : (dish.obstruction.fraction ?? 0) > 0.02 ? .warn : .ok))

        if let valid = dish.gpsValid {
            list.append(Component(name: "GPS", icon: "location", status: valid ? "\(dish.gpsSats ?? 0) satellites" : "No fix", level: valid ? .ok : .warn))
        }

        if let problem = has("No Ethernet link", "Slow Ethernet (10 Mbps)", "Slow Ethernet (100 Mbps)", "Router port slow") {
            list.append(Component(name: "Ethernet", icon: "cable.connector", status: problem, level: problem == "No Ethernet link" ? .bad : .warn))
        } else {
            list.append(Component(name: "Ethernet", icon: "cable.connector", status: dish.ethSpeedMbps.map { "\($0) Mbps" } ?? "Connected"))
        }

        if let problem = has("Thermal shutdown", "Thermal throttling") {
            list.append(Component(name: "Temperature", icon: "thermometer.medium", status: problem, level: problem == "Thermal shutdown" ? .bad : .warn))
        } else {
            list.append(Component(name: "Temperature", icon: "thermometer.medium",
                                  status: alerts.contains("Heating (snow melt)") ? "Heating to melt snow" : "Normal"))
        }

        list.append(Component(name: "Power", icon: "bolt",
                              status: alerts.contains("Power supply thermal throttling") ? "Running hot" : store.powerW.map { Fmt.watts($0) } ?? "Normal",
                              level: alerts.contains("Power supply thermal throttling") ? .warn : .ok))

        if dish.alignment.hasActuators == true {
            let problem = has("Motors stuck", "Low motor current")
            list.append(Component(name: "Motors", icon: "gearshape.2", status: problem ?? "Working", level: problem == nil ? .ok : .bad))
        } else {
            list.append(Component(name: "Mount", icon: "gearshape.2", status: "Fixed", level: .idle))
        }

        if alerts.contains("Mast not near vertical") {
            list.append(Component(name: "Mast", icon: "arrow.up.to.line", status: "Not near vertical", level: .warn))
        }

        let water = has("Water detected in dish", "Water detected in router")
        list.append(Component(name: "Moisture", icon: "drop", status: water ?? "Dry", level: water == nil ? .ok : .bad))

        let update = dish.softwareUpdateState
        list.append(Component(name: "Software", icon: "arrow.down.circle", status: Names.softwareUpdate(update),
                              level: update == 8 ? .bad : update == 6 ? .warn : update == nil ? .idle : .ok))

        if let router = store.router {
            list.append(Component(name: "Router", icon: "wifi.router", status: router.alerts.first ?? (router.noWanLink ? "No link to dish" : "Connected"),
                                  level: router.noWanLink ? .bad : router.alerts.isEmpty ? .ok : .warn))
        } else {
            list.append(Component(name: "Router", icon: "wifi.router", status: "No Starlink router", level: .idle))
        }
        return list
    }
}

/// Alerts StarDash has seen come and go. The dish only ever reports the ones raised right now.
struct AlertHistory: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        let log = store.alertLog
        let active = log.filter(\.isActive).count
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Alert history", trailing: log.isEmpty ? nil : active == 0 ? "None active" : "\(active) active")
                if log.isEmpty {
                    Text("No alerts since StarDash started keeping track. The dish only reports alerts while they're raised, so this list builds up from now on.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(log.prefix(30)) { record in
                    let benign = DishStatus.benignAlerts.contains(record.name)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(record.isActive ? (benign ? Color.white.opacity(0.6) : Palette.warn) : .white.opacity(0.2))
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(record.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(record.source).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        if benign { Text("informational").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3)) }
                        Spacer(minLength: 8)
                        Text(Fmt.dayClock.string(from: record.start)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        Text(record.isActive ? "Active" : "for \(Fmt.duration(record.duration))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(record.isActive && !benign ? Palette.warn : .white.opacity(0.6))
                            .frame(width: 92, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
            }
        }
    }
}
