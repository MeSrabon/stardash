import SwiftUI

/// The Rules section on the Network page.
struct RulesPanel: View {
    var clients: [WifiClient]
    @Environment(Overlays.self) private var overlays
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        let engine = RulesEngine.shared
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Rules", trailing: "Checked every 15 seconds while StarDash runs")
                if engine.rules.isEmpty {
                    Text("Limit a device's data, set the hours it can be online, or give it a timer. When a rule says a device should be off, StarDash pauses it through your Starlink account, the way the Starlink app does.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                ForEach(engine.rules) { rule in
                    RuleRow(rule: rule, edit: { open(rule) }, remove: { confirmDelete(rule) })
                }
                HStack {
                    Button("Add rule…") { open(nil) }
                        .disabled(selectable.isEmpty)
                    Spacer()
                    Text("Data is counted from the router while StarDash runs.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { if !engine.rules.isEmpty { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) } }
            }
        }
        .buttonStyle(QuietButton())
        .toggleStyle(ThemedSwitch())
    }

    /// Devices a rule can name: ones the router numbers, and never this Mac.
    private var selectable: [WifiClient] {
        clients.filter { $0.clientID != nil && !($0.ip.map(store.localIPs.contains) ?? false) }
    }

    private func open(_ rule: NetworkRule?) {
        overlays.sheet = SheetRequest(id: "rule-\(rule?.id.uuidString ?? "new")", width: 600,
                                      content: AnyView(RuleEditor(rule: rule, clients: selectable)))
    }

    private func confirmDelete(_ rule: NetworkRule) {
        overlays.confirm = ConfirmRequest(
            title: "Delete \(rule.name)?",
            message: "Devices this rule paused get their internet back.",
            action: "Delete"
        ) { RulesEngine.shared.delete(rule.id) }
    }
}

private struct RuleRow: View {
    var rule: NetworkRule
    var edit: () -> Void
    var remove: () -> Void

    var body: some View {
        let engine = RulesEngine.shared
        let state = engine.state(of: rule)
        let held = rule.enabled ? rule.devices.filter { state.held.contains($0.id) } : []
        let failures = held.compactMap { engine.pauses[$0.id]?.state == .failed ? engine.pauses[$0.id]?.error : nil }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rule.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !rule.enabled {
                    Pill(text: "Off", color: .white.opacity(0.5))
                } else if let reason = state.reason, !held.isEmpty {
                    Pill(text: reason, color: Palette.warn)
                } else {
                    Pill(text: "Online", color: Palette.good)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { engine.setEnabled(rule.id, $0) })).labelsHidden()
            }
            Text(rule.devices.map { device in
                engine.pauses[device.id]?.state == .applied ? "\(device.name) (paused)" : device.name
            }.joined(separator: ", "))
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            ForEach(state.lines, id: \.self) { line in
                Text(line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).monospacedDigit()
            }
            if let failure = failures.first {
                Text("Couldn't pause: \(failure)").font(.system(size: 11)).foregroundStyle(Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Edit…", action: edit)
                if rule.timer != nil {
                    Button("Start timer again") { engine.restartTimer(rule.id) }
                }
                Button { remove() } label: { Text("Delete…").foregroundStyle(Palette.bad) }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
}

// MARK: Editor

struct RuleEditor: View {
    var original: NetworkRule?
    var clients: [WifiClient]
    @Environment(Overlays.self) private var overlays

    @State private var name: String
    @State private var chosen: Set<String>
    @State private var known: [RuleDevice]

    @State private var limitOn: Bool
    @State private var limitGB: Double
    @State private var period: LimitPeriod
    @State private var shared: Bool

    @State private var hoursOn: Bool
    @State private var weekdaysOn: Bool
    @State private var weekdays: HourSpan
    @State private var weekendOn: Bool
    @State private var weekend: HourSpan

    @State private var timerOn: Bool
    @State private var timerMinutes: Int

    private static let sizes: [Double] = [0.5, 1, 2, 3, 5, 10, 20, 50, 100, 200, 500]
    private static let timers = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440]
    private static let halfHours = stride(from: 0, to: 1440, by: 30).map { ($0, OnlineHours.clock($0)) }

    init(rule: NetworkRule?, clients: [WifiClient]) {
        original = rule
        self.clients = clients
        var devices = clients.map(RuleDevice.init)
        for device in rule?.devices ?? [] where !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
        _known = State(initialValue: devices)
        _name = State(initialValue: rule?.name ?? "")
        _chosen = State(initialValue: Set(rule?.devices.map(\.id) ?? []))
        _limitOn = State(initialValue: rule?.limit != nil)
        _limitGB = State(initialValue: rule?.limit.map { $0.bytes / 1e9 } ?? 5)
        _period = State(initialValue: rule?.limit?.period ?? .day)
        _shared = State(initialValue: rule?.limit?.shared ?? true)
        _hoursOn = State(initialValue: rule?.hours != nil)
        _weekdaysOn = State(initialValue: rule?.hours.map { $0.weekdays != nil } ?? true)
        _weekdays = State(initialValue: rule?.hours?.weekdays ?? HourSpan(start: 16 * 60, end: 20 * 60))
        _weekendOn = State(initialValue: rule?.hours.map { $0.weekend != nil } ?? true)
        _weekend = State(initialValue: rule?.hours?.weekend ?? HourSpan(start: 9 * 60, end: 21 * 60))
        _timerOn = State(initialValue: rule?.timer != nil)
        _timerMinutes = State(initialValue: rule?.timer?.minutes ?? 60)
    }

    private var problem: String? {
        if chosen.isEmpty { return "Pick at least one device." }
        if !limitOn && !hoursOn && !timerOn { return "Turn on a data limit, online hours or a timer." }
        if hoursOn && !weekdaysOn && !weekendOn { return "Pick hours for weekdays, the weekend or both." }
        if hoursOn && ((weekdaysOn && weekdays.start == weekdays.end) || (weekendOn && weekend.start == weekend.end)) {
            return "Online hours need a different start and end."
        }
        return nil
    }

    var body: some View {
        EditorFrame(title: original == nil ? "New rule" : "Edit rule",
                    detail: "When a rule says a device should be off, StarDash pauses it through your Starlink account. It stays on the Wi-Fi but can't reach the internet. A paused device you resume by hand stays resumed until the rule would let it go.",
                    problem: problem, save: "Save", canSave: problem == nil) {
            save()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormField(label: "Name", placeholder: "Kids' tablets", text: $name)
                    devicesPicker
                    section("Data limit", isOn: $limitOn) {
                        HStack(spacing: 8) {
                            DropPicker(options: Self.sizes.map { ($0, $0 < 1 ? "\(Int($0 * 1000)) MB" : "\(Int($0)) GB") }, selection: $limitGB)
                            DropPicker(options: LimitPeriod.allCases.map { ($0, periodLabel($0)) }, selection: $period)
                            if chosen.count > 1 {
                                DropPicker(options: [(true, "Shared by all"), (false, "For each device")], selection: $shared)
                            }
                        }
                        if period == .billing, Account.shared.billing?.billingDay == nil {
                            note("Your billing day isn't known yet, so the cycle starts on the 1st.")
                        }
                    }
                    section("Online hours", isOn: $hoursOn) {
                        spanRow("Weekdays", on: $weekdaysOn, span: $weekdays)
                        spanRow("Weekend", on: $weekendOn, span: $weekend)
                        note("Outside these hours the devices are paused. Days without hours are left alone.")
                    }
                    section("Timer", isOn: $timerOn) {
                        HStack(spacing: 8) {
                            Text("Allow for").font(.system(size: 12.5))
                            DropPicker(options: Self.timers.map { ($0, RuleTimer.label($0)) }, selection: $timerMinutes)
                        }
                        note("Starts when you save. When it runs out the devices stay paused until you start it again.")
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 380)
        }
        .toggleStyle(ThemedSwitch())
        .task { await Account.shared.loadBilling() }
    }

    private func periodLabel(_ period: LimitPeriod) -> String {
        if period == .billing, let day = Account.shared.billing?.billingDay { return "Each billing cycle (from the \(Self.ordinal(day)))" }
        return period.label
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }

    private var devicesPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("Devices")
            if known.isEmpty {
                note("No devices the router can pause right now.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(known) { device in
                    let on = chosen.contains(device.id)
                    Button {
                        if on { chosen.remove(device.id) } else { chosen.insert(device.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                            Text(device.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .foregroundStyle(on ? Theme.onAccent : .white.opacity(0.7))
                        .background(on ? Palette.accent.opacity(0.85) : .white.opacity(0.07), in: Pillow())
                        .overlay(Pillow().strokeBorder(.white.opacity(on ? 0.3 : 0.1)))
                        .contentShape(Pillow())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("This Mac isn't listed. StarDash won't pause the Mac it runs on.")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private func section(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) { Kicker(title) }
                .toggleStyle(ThemedSwitch(spread: true))
            if isOn.wrappedValue {
                VStack(alignment: .leading, spacing: 8) { content() }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func spanRow(_ label: String, on: Binding<Bool>, span: Binding<HourSpan>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: on).labelsHidden()
            Text(label).font(.system(size: 12.5)).frame(width: 74, alignment: .leading)
            if on.wrappedValue {
                DropPicker(options: Self.halfHours, selection: span.start)
                Text("to").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                DropPicker(options: Self.halfHours, selection: span.end)
            } else {
                Text("No limit").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        var rule = original ?? NetworkRule(name: "", devices: [])
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        rule.devices = known.filter { chosen.contains($0.id) }
        rule.name = trimmed.isEmpty ? (rule.devices.count == 1 ? rule.devices[0].name : "Rule") : trimmed
        rule.limit = limitOn ? DataLimit(bytes: limitGB * 1e9, period: period, shared: chosen.count > 1 ? shared : true,
                                         billingDay: Account.shared.billing?.billingDay ?? original?.limit?.billingDay ?? 1) : nil
        rule.hours = hoursOn ? OnlineHours(weekdays: weekdaysOn ? weekdays : nil, weekend: weekendOn ? weekend : nil) : nil
        if timerOn {
            // A new length starts the clock again. Leaving it alone keeps the time already used.
            if rule.timer?.minutes != timerMinutes { rule.timer = RuleTimer(minutes: timerMinutes, started: Date()) }
        } else {
            rule.timer = nil
        }

        let engine = RulesEngine.shared
        let state = engine.state(of: rule)
        let pausing = rule.enabled ? rule.devices.filter { state.held.contains($0.id) && engine.pauses[$0.id]?.state != .applied } : []
        guard !pausing.isEmpty else {
            engine.upsert(rule)
            overlays.sheet = nil
            return
        }
        let names = pausing.map(\.name).joined(separator: ", ")
        overlays.confirm = ConfirmRequest(
            title: "Save and pause now?",
            message: "\(names) will be paused straight away (\((state.reason ?? "rule in force").lowercased())). They keep their Wi-Fi but lose the internet until the rule lets them go.",
            action: "Save and pause"
        ) {
            engine.upsert(rule)
            overlays.sheet = nil
        }
    }
}

// MARK: Device card

/// Pause and resume on the device card. Shown only when signed in.
struct DevicePauseControl: View {
    var client: WifiClient
    var isThisMac: Bool
    @Environment(Overlays.self) private var overlays
    @State private var working = false
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        let key = client.clientID.map(RuleDevice.key)
        let record = key.flatMap { RulesEngine.shared.pauses[$0] }
        // The router's own flag is the truth. A write StarDash just sent shows up there a few seconds later.
        let paused = client.blocked || record?.state == .applied
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "Internet paused" : "Internet").font(.system(size: 13))
                Text(detail(key: key, paused: paused))
                    .font(.system(size: 11)).foregroundStyle(noteIsError ? Palette.bad : .white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !isThisMac, client.clientID != nil {
                Button(working ? "Sending…" : paused ? "Resume…" : "Pause…") { confirm(paused: paused) }
                    .buttonStyle(QuietButton())
                    .disabled(working)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func detail(key: String?, paused: Bool) -> String {
        if let note { return note }
        if isThisMac { return "StarDash won't pause the Mac it runs on. Nothing here could resume it." }
        if client.clientID == nil { return "The router hasn't given this device a number, so it can't be paused." }
        if let key, let text = RulesEngine.shared.pauseNote(key) { return text }
        return paused ? "Paused on the router. It keeps its Wi-Fi but can't reach the internet."
            : "Pausing keeps it on the Wi-Fi but cuts its internet, through your Starlink account."
    }

    private func confirm(paused: Bool) {
        let name = client.name
        overlays.confirm = paused
            ? ConfirmRequest(title: "Resume \(name)?",
                             message: "It gets its internet back straight away. If a rule wants it off, the rule leaves it alone until it would let go.",
                             action: "Resume", destructive: false) { send(false) }
            : ConfirmRequest(title: "Pause \(name)?",
                             message: "It stays on the Wi-Fi but can't reach the internet until you resume it here or in the Starlink app. Rules won't resume a device you paused by hand.",
                             action: "Pause") { send(true) }
    }

    private func send(_ pause: Bool) {
        working = true
        Task {
            let problem = await RulesEngine.shared.setPausedByHand(client, paused: pause)
            working = false
            note = problem ?? (pause ? "Paused. The router shows it in a few seconds." : "Resumed. The router shows it in a few seconds.")
            noteIsError = problem != nil
        }
    }
}
