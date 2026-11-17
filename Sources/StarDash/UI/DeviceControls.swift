import SwiftUI

/// Settings and actions that change the dish or router. Each one says what it will do before it does it.
struct DishControls: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(Overlays.self) private var overlays
    var dish: DishStatus
    @State private var note: String?
    @State private var noteIsError = false

    private static func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    var body: some View {
        let config = store.dishConfig
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Controls", trailing: config == nil ? "Reading the dish's settings…" : "Changes apply to the dish straight away")
                if let config {
                    row("Snow melt", "Heats the dish to clear snow. Uses more power while it runs.") {
                        DropPicker(options: DishConfig.SnowMelt.allCases.map { ($0, $0.label) },
                                   selection: Binding(get: { config.snowMelt }, set: { send(.snowMelt($0), done: "Snow melt set to \($0.label.lowercased()).") }))
                    }
                    row("Sleep schedule", config.sleepEnabled
                        ? "The dish goes offline every day from \(Self.hourLabel(config.sleepStartLocalHour)) for \(config.sleepDurationMinutes / 60) hours."
                        : "Switches the dish off for part of each day to save power. Off now.") {
                        HStack(spacing: 8) {
                            if config.sleepEnabled {
                                DropPicker(options: (0..<24).map { ($0, Self.hourLabel($0)) },
                                           selection: Binding(get: { config.sleepStartLocalHour }, set: { hour in
                                               send(.sleep(enabled: true, startMinutesUTC: DishConfig.utcMinutes(localHour: hour),
                                                           durationMinutes: max(60, config.sleepDurationMinutes)), done: "Sleep now starts at \(Self.hourLabel(hour)).")
                                           }))
                                DropPicker(options: (1...12).map { ($0 * 60, "\($0) h") },
                                           selection: Binding(get: { max(60, config.sleepDurationMinutes / 60 * 60) }, set: { minutes in
                                               send(.sleep(enabled: true, startMinutesUTC: config.sleepStartMinutes, durationMinutes: minutes),
                                                    done: "Sleep now lasts \(minutes / 60) hours.")
                                           }))
                            }
                            Toggle("", isOn: Binding(get: { config.sleepEnabled }, set: { on in
                                if on {
                                    let start = config.sleepDurationMinutes > 0 ? config.sleepStartMinutes : DishConfig.utcMinutes(localHour: 1)
                                    let duration = config.sleepDurationMinutes > 0 ? config.sleepDurationMinutes : 300
                                    let local = ((start + TimeZone.current.secondsFromGMT() / 60) % 1440 + 1440) % 1440 / 60
                                    overlays.confirm = ConfirmRequest(
                                        title: "Turn on the sleep schedule?",
                                        message: "The dish, and your internet, will switch off every day from \(Self.hourLabel(local)) for \(duration / 60) hours. You can change the times afterwards.",
                                        action: "Turn on"
                                    ) { send(.sleep(enabled: true, startMinutesUTC: start, durationMinutes: duration), done: "Sleep schedule is on.") }
                                } else {
                                    send(.sleep(enabled: false, startMinutesUTC: config.sleepStartMinutes, durationMinutes: config.sleepDurationMinutes),
                                         done: "Sleep schedule is off.")
                                }
                            })).labelsHidden()
                        }
                    }
                    row("Update time", "The hour the dish restarts to install new software. It's offline for a few minutes.") {
                        DropPicker(options: (0..<24).map { ($0, Self.hourLabel($0)) },
                                   selection: Binding(get: { config.updateHour }, set: { send(.updateHour($0), done: "Updates now install around \(Self.hourLabel($0)).") }))
                    }
                    row("Hold updates for three days", "Waits before taking new software, in case an update turns out to be faulty.") {
                        Toggle("", isOn: Binding(get: { config.deferUpdates }, set: { send(.deferUpdates($0), done: $0 ? "Updates are held for three days." : "Updates install as they arrive.") }))
                            .labelsHidden()
                    }
                }
                HStack(spacing: 10) {
                    Button("Reset obstruction map…") {
                        overlays.confirm = ConfirmRequest(
                            title: "Reset the obstruction map?",
                            message: "The dish forgets what it has learned about its view of the sky and starts again, which takes several hours. Worth doing after moving the dish or clearing an obstruction. The time-lapse starts over too.",
                            action: "Reset map"
                        ) { run("Obstruction map reset. It rebuilds over the next hours.") { await store.clearObstructionMap() } }
                    }
                    if store.router != nil {
                        Button("Reboot router…") {
                            overlays.confirm = ConfirmRequest(
                                title: "Reboot the router?",
                                message: "Wi-Fi drops for everything on this network for a minute or two.",
                                action: "Reboot"
                            ) { run("Router reboot requested.") { await store.rebootRouter() } }
                        }
                    }
                    if dish.alignment.hasActuators == true {
                        Button(dish.stowRequested ? "Unstow dish" : "Stow dish…") {
                            if dish.stowRequested {
                                run("Unstow requested.") { await store.stowDish(false) }
                            } else {
                                overlays.confirm = ConfirmRequest(
                                    title: "Stow the dish?",
                                    message: "The dish folds flat for transport and goes offline until you unstow it.",
                                    action: "Stow"
                                ) { run("Stow requested.") { await store.stowDish(true) } }
                            }
                        }
                    }
                    Spacer()
                    if let note {
                        Text(note).font(.system(size: 11.5)).foregroundStyle(noteIsError ? Palette.bad : .white.opacity(0.6))
                            .lineLimit(2).multilineTextAlignment(.trailing)
                    }
                }
                .buttonStyle(QuietButton())
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
            }
        }
        .toggleStyle(ThemedSwitch())
        .task { await store.loadDishConfig() }
    }

    private func row(_ title: String, _ detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func send(_ change: DishChange, done: String) {
        Task {
            let problem = await store.apply(change)
            note = problem.map { "The dish refused: \($0)" } ?? done
            noteIsError = problem != nil
        }
    }

    private func run(_ done: String, _ action: @escaping () async -> Bool) {
        Task {
            let ok = await action()
            note = ok ? done : "That didn't go through."
            noteIsError = !ok
        }
    }
}
