import Foundation
import Observation

// Network rules: data limits, online hours and timers for devices on the Starlink router.
// Rules are kept on this Mac and checked by StarDash while it runs. When one says a device should be
// off, StarDash pauses it through the Starlink account, the way the Starlink app does. The rule shapes
// follow Dishylink's (core/dataMeter.ts, core/schedule.ts, core/devicePause.ts), simplified.

/// A device a rule applies to. The router's client number is the only handle that's unique:
/// the router hides the end of every hardware address, so devices from one maker can share one.
struct RuleDevice: Codable, Hashable, Identifiable {
    var clientID: UInt64
    var mac: String?
    var name: String

    var id: String { Self.key(clientID) }

    static func key(_ clientID: UInt64) -> String { "client-\(clientID)" }

    init(_ client: WifiClient) {
        clientID = client.clientID ?? 0
        mac = client.mac
        name = client.name
    }
}

enum LimitPeriod: String, Codable, CaseIterable {
    case day, week, month, billing

    var label: String {
        switch self {
        case .day: return "Each day"
        case .week: return "Each week"
        case .month: return "Each month"
        case .billing: return "Each billing cycle"
        }
    }

    var phrase: String {
        switch self {
        case .day: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .billing: return "this billing cycle"
        }
    }
}

struct DataLimit: Codable, Equatable {
    var bytes: Double
    var period: LimitPeriod
    /// One allowance for the whole group, or the same allowance for each device.
    var shared: Bool
    /// Day of the month the bill starts, copied from the account when the rule was saved.
    var billingDay: Int = 1
}

/// Minutes from midnight. An end at or before the start runs past midnight into the next day.
struct HourSpan: Codable, Equatable {
    var start: Int
    var end: Int

    var length: Int { end > start ? end - start : end + 1440 - start }
}

/// When devices may be online. Outside these hours they're paused. A missing span leaves
/// those days alone.
struct OnlineHours: Codable, Equatable {
    var weekdays: HourSpan?
    var weekend: HourSpan?

    private static var calendar: Calendar { .current }

    func span(on day: Date) -> HourSpan? {
        Self.calendar.isDateInWeekend(day) ? weekend : weekdays
    }

    private static func minute(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// A clock time on a given day, built from the day's own parts so it holds across clock changes.
    private static func time(_ day: Date, _ minute: Int) -> Date {
        let shifted = calendar.date(byAdding: .day, value: minute / 1440, to: day) ?? day
        let m = minute % 1440
        return calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: shifted) ?? shifted
    }

    func blocked(at date: Date) -> Bool {
        let cal = Self.calendar
        let today = cal.startOfDay(for: date)
        let minute = Self.minute(date)
        if let s = span(on: today), minute >= s.start, minute < s.start + s.length { return false }
        // Last night's window may still be running.
        if let yesterday = cal.date(byAdding: .day, value: -1, to: today), let s = span(on: yesterday),
           s.start + s.length > 1440, minute < s.start + s.length - 1440 { return false }
        return span(on: today) != nil
    }

    /// When the answer next flips, looking up to a week ahead.
    func nextChange(after date: Date) -> Date? {
        let cal = Self.calendar
        let now = blocked(at: date)
        let today = cal.startOfDay(for: date)
        var candidates: [Date] = []
        for offset in -1...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            candidates.append(day)
            if let s = span(on: day) {
                candidates.append(Self.time(day, s.start))
                candidates.append(Self.time(day, s.start + s.length))
            }
        }
        return candidates.filter { $0 > date }.sorted().first { blocked(at: $0) != now }
    }

    var summary: String {
        var parts: [String] = []
        if let w = weekdays { parts.append("\(Self.clock(w.start)) to \(Self.clock(w.end)) on weekdays") }
        if let w = weekend { parts.append("\(Self.clock(w.start)) to \(Self.clock(w.end)) at the weekend") }
        return parts.isEmpty ? "Any time" : "Online " + parts.joined(separator: ", ")
    }

    static func clock(_ minute: Int) -> String {
        let m = minute % 1440
        let h = m / 60
        let hour = h % 12 == 0 ? 12 : h % 12
        let mins = m % 60
        return mins == 0 ? "\(hour) \(h < 12 ? "AM" : "PM")" : String(format: "%d:%02d %@", hour, mins, h < 12 ? "AM" : "PM")
    }
}

/// Lets devices online for a set time from when it starts. When it runs out they stay paused
/// until the timer is started again or removed.
struct RuleTimer: Codable, Equatable {
    var minutes: Int
    var started: Date

    /// "15 min", "1 hour", "1 h 30 min".
    static func label(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return h == 1 ? "1 hour" : "\(h) hours" }
        return "\(h) h \(m) min"
    }

    var ends: Date { started.addingTimeInterval(Double(minutes) * 60) }
    func spent(at date: Date) -> Bool { date >= ends }
}

struct NetworkRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var devices: [RuleDevice]
    var enabled = true
    var limit: DataLimit?
    var hours: OnlineHours?
    var timer: RuleTimer?
    var created = Date()

    var isEmpty: Bool { limit == nil && hours == nil && timer == nil }
}

/// What StarDash last did to a device's pause, so a write that failed never reads as a limit in force.
struct PauseRecord: Codable, Equatable {
    enum State: String, Codable { case pending, applied, failed }
    enum Kind: String, Codable { case pause, release }

    var clientID: UInt64
    var name: String
    var state: State
    var attempted: Kind
    var checked: Date
    /// Paused from the device card rather than by a rule. Rules never resume these.
    var manual = false
    /// When the router's own device list first showed the block.
    var confirmed: Date?
    var error: String?
}

/// Traffic per device per day, counted the same way as the monthly totals on the Usage page:
/// the router's byte counters for each device, adding up each increase.
struct UsageLedger: Codable {
    /// Device key, then local day ("2026-11-19"), then bytes both ways.
    var days: [String: [String: Double]] = [:]
    /// The router's counter at the last look, to take the next increase from.
    var last: [String: Double] = [:]

    static let keptDays = 70

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func record(_ clients: [WifiClient], at date: Date) {
        let today = Self.dayKey(date)
        for client in clients where !client.isInfrastructure {
            guard let id = client.clientID else { continue }
            let key = RuleDevice.key(id)
            var counter = Double(client.txBytes + client.rxBytes)
            if counter == 0 { counter = Double((client.downloadMB ?? 0) + (client.uploadMB ?? 0)) * 1e6 }
            guard let previous = last[key] else {
                last[key] = counter
                continue
            }
            // A counter that went down means the device rejoined and the router started over.
            let added = counter >= previous ? counter - previous : counter
            last[key] = counter
            if added > 0 { days[key, default: [:]][today, default: 0] += added }
        }
        prune(before: date)
    }

    private mutating func prune(before date: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keptDays, to: date) else { return }
        let oldest = Self.dayKey(cutoff)
        for key in days.keys {
            days[key] = days[key]?.filter { $0.key >= oldest }
        }
    }

    func bytes(_ key: String, since start: Date) -> Double {
        let first = Self.dayKey(start)
        return (days[key] ?? [:]).reduce(0) { $0 + ($1.key >= first ? $1.value : 0) }
    }
}

extension DataLimit {
    func periodStart(at date: Date) -> Date {
        let cal = Calendar.current
        switch period {
        case .day: return cal.startOfDay(for: date)
        case .week: return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
        case .month: return cal.dateInterval(of: .month, for: date)?.start ?? cal.startOfDay(for: date)
        case .billing:
            // The bill starts on the same day each month, moved earlier in months that are too short.
            func start(monthOffset: Int) -> Date {
                let month = cal.date(byAdding: .month, value: monthOffset, to: cal.dateInterval(of: .month, for: date)?.start ?? date) ?? date
                let days = cal.range(of: .day, in: .month, for: month)?.count ?? 28
                return cal.date(byAdding: .day, value: min(billingDay, days) - 1, to: month) ?? month
            }
            let thisMonth = start(monthOffset: 0)
            return date >= thisMonth ? thisMonth : start(monthOffset: -1)
        }
    }
}

/// How one rule stands right now.
struct RuleState {
    /// Devices this rule wants off the internet.
    var held: Set<String> = []
    var lines: [String] = []
    /// The limit, timer or schedule that is holding devices, in a few words.
    var reason: String?
}

@MainActor
@Observable
final class RulesEngine {
    static let shared = RulesEngine()
    /// A write that failed or didn't show up on the router is tried again after this long.
    private static let retry: TimeInterval = 60
    /// How often rules are checked.
    private static let interval: TimeInterval = 15

    private(set) var rules: [NetworkRule] = []
    private(set) var pauses: [String: PauseRecord] = [:]
    /// Devices resumed by hand while a rule still wanted them off. The rule leaves them be until it lets go.
    private(set) var overrides: Set<String> = []
    private(set) var ledger = UsageLedger()
    private(set) var lastCheck: Date?

    @ObservationIgnored private weak var store: TelemetryStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var running = false

    private struct Stored: Codable {
        var rules: [NetworkRule]
        var pauses: [String: PauseRecord]
        var overrides: Set<String>
        var ledger: UsageLedger
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("rules.json")
    }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: Self.fileURL), let stored = try? decoder.decode(Stored.self, from: data) {
            rules = stored.rules
            pauses = stored.pauses
            overrides = stored.overrides
            ledger = stored.ledger
        }
    }

    /// Starts checking rules in the background. Safe to call more than once.
    func start(store: TelemetryStore) {
        self.store = store
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    private func save() {
        let stored = Stored(rules: rules, pauses: pauses, overrides: overrides, ledger: ledger)
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let json = try? encoder.encode(stored) { try? json.write(to: url, options: .atomic) }
        }
    }

    // MARK: Editing

    func upsert(_ rule: NetworkRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        save()
        Task { await check() }
    }

    func delete(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
        Task { await check() }
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = on
        save()
        Task { await check() }
    }

    func restartTimer(_ id: UUID) {
        guard let i = rules.firstIndex(where: { $0.id == id }), rules[i].timer != nil else { return }
        rules[i].timer?.started = Date()
        save()
        Task { await check() }
    }

    // MARK: Reading

    func usage(_ device: RuleDevice, _ limit: DataLimit, at date: Date = Date()) -> Double {
        ledger.bytes(device.id, since: limit.periodStart(at: date))
    }

    func state(of rule: NetworkRule, at date: Date = Date()) -> RuleState {
        var state = RuleState()
        guard !rule.devices.isEmpty else { return state }
        let all = Set(rule.devices.map(\.id))
        var reasons: [String] = []

        if let limit = rule.limit {
            let used = rule.devices.map { ($0, usage($0, limit, at: date)) }
            if limit.shared {
                let total = used.reduce(0) { $0 + $1.1 }
                state.lines.append("\(Fmt.data(total)) of \(Fmt.data(limit.bytes)) \(limit.period.phrase)\(rule.devices.count > 1 ? " between them" : "")")
                if total >= limit.bytes {
                    state.held.formUnion(all)
                    reasons.append("Data limit reached")
                }
            } else {
                let top = used.max { $0.1 < $1.1 }
                state.lines.append("Up to \(Fmt.data(limit.bytes)) each \(limit.period.phrase). Most so far: \(top.map { "\($0.0.name), \(Fmt.data($0.1))" } ?? "none")")
                let over = used.filter { $0.1 >= limit.bytes }
                if !over.isEmpty {
                    state.held.formUnion(over.map { $0.0.id })
                    reasons.append(over.count == rule.devices.count ? "Data limit reached" : "\(over.count) over the data limit")
                }
            }
        }

        if let hours = rule.hours {
            let blocked = hours.blocked(at: date)
            var line = hours.summary
            if let next = hours.nextChange(after: date) {
                line += blocked ? ". Back online \(Self.when(next))" : ". Online until \(Self.when(next))"
            }
            state.lines.append(line)
            if blocked {
                state.held.formUnion(all)
                reasons.append("Outside online hours")
            }
        }

        if let timer = rule.timer {
            if timer.spent(at: date) {
                state.lines.append("Time's up. Paused until the timer starts again.")
                state.held.formUnion(all)
                reasons.append("Timer ran out")
            } else {
                let left = max(1, Int(ceil(timer.ends.timeIntervalSince(date) / 60)))
                state.lines.append("Online for \(RuleTimer.label(timer.minutes)), \(RuleTimer.label(left)) left")
            }
        }
        state.reason = reasons.first
        return state
    }

    /// "at 4 PM", "tomorrow at 9 AM", "on Saturday at 9 AM".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = OnlineHours.clock(cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date))
        if cal.isDateInToday(date) { return "at \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let day = date.formatted(.dateTime.weekday(.wide))
        return "on \(day) at \(time)"
    }

    /// Every device some enabled rule wants off right now.
    func wanted(at date: Date = Date()) -> Set<String> {
        rules.filter(\.enabled).reduce(into: Set<String>()) { $0.formUnion(state(of: $1, at: date).held) }
    }

    // MARK: Checking

    /// For TelemetryStore to call after each router poll, so new traffic counts straight away.
    func routerUpdated() {
        Task { await check() }
    }

    /// Folds in the latest traffic, works out which devices should be off, and pauses or resumes
    /// what disagrees. Writes go through the Starlink account, one at a time.
    func check() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let now = Date()
        lastCheck = now
        let clients = store?.router?.clients ?? []
        if !clients.isEmpty { ledger.record(clients, at: now) }

        let wanted = wanted(at: now)
        // A hand resume only stands while the rule that was overruled still holds.
        overrides = overrides.intersection(wanted)
        defer { save() }

        guard Account.shared.signedIn, !rules.isEmpty || !pauses.isEmpty else { return }
        let live = Dictionary(clients.compactMap { c in c.clientID.map { (RuleDevice.key($0), c) } }, uniquingKeysWith: { a, _ in a })
        let protect = store?.localIPs ?? []
        let devices = Dictionary(rules.flatMap(\.devices).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Settle what the router now shows.
        for (key, record) in pauses {
            guard let client = live[key], record.state == .applied else { continue }
            if record.confirmed == nil, client.blocked {
                pauses[key]?.confirmed = now
            } else if record.confirmed != nil, !client.blocked {
                // Someone resumed it, here or in the Starlink app. Their choice stands.
                pauses[key] = nil
                if wanted.contains(key) { overrides.insert(key) }
            }
        }

        for key in wanted.subtracting(overrides).sorted() {
            guard let device = devices[key] else { continue }
            if let ip = live[key]?.ip, protect.contains(ip) { continue }
            let record = pauses[key]
            let due: Bool
            switch record?.state {
            case nil: due = true
            // Only asked again when the router's own list can show whether the first one landed.
            case .applied?: due = !clients.isEmpty && record?.confirmed == nil && now.timeIntervalSince(record?.checked ?? now) >= Self.retry
            case .pending?, .failed?: due = record?.attempted != .pause || now.timeIntervalSince(record?.checked ?? now) >= Self.retry
            }
            guard due else { continue }
            // A device that isn't connected can't be paused. It'll be caught when it comes back.
            if !clients.isEmpty, live[key] == nil { continue }
            await send(device.clientID, name: device.name, key: key, pause: true, manual: false, protect: protect)
        }

        for (key, record) in pauses where !record.manual && !wanted.contains(key) {
            if record.attempted == .release, now.timeIntervalSince(record.checked) < Self.retry { continue }
            await send(record.clientID, name: record.name, key: key, pause: false, manual: false, protect: protect)
        }
    }

    private func send(_ clientID: UInt64, name: String, key: String, pause: Bool, manual: Bool, protect: Set<String>) async {
        pauses[key] = PauseRecord(clientID: clientID, name: name, state: .pending, attempted: pause ? .pause : .release,
                                  checked: Date(), manual: manual || (pauses[key]?.manual ?? false))
        let problem = await Account.shared.setPaused(clientID: clientID, paused: pause, protect: protect)
        if let problem {
            pauses[key]?.state = .failed
            pauses[key]?.error = problem
            pauses[key]?.checked = Date()
        } else if pause {
            pauses[key]?.state = .applied
            pauses[key]?.error = nil
            pauses[key]?.checked = Date()
        } else {
            pauses[key] = nil
        }
    }

    /// Pause or resume from the device card. Returns nil on success, or what went wrong.
    func setPausedByHand(_ client: WifiClient, paused: Bool) async -> String? {
        guard let id = client.clientID else { return "The router hasn't given this device a number, so it can't be paused." }
        let key = RuleDevice.key(id)
        let protect = store?.localIPs ?? []
        let problem = await Account.shared.setPaused(clientID: id, paused: paused, protect: protect)
        guard problem == nil else { return problem }
        if paused {
            pauses[key] = PauseRecord(clientID: id, name: client.name, state: .applied, attempted: .pause,
                                      checked: Date(), manual: true)
            overrides.remove(key)
        } else {
            pauses[key] = nil
            if wanted().contains(key) { overrides.insert(key) }
        }
        save()
        return nil
    }

    /// What StarDash knows about one device's pause, for the device card and rule rows.
    func pauseNote(_ key: String) -> String? {
        guard let record = pauses[key] else { return overrides.contains(key) ? "Resumed by hand. Its rule waits until it would let go." : nil }
        switch record.state {
        case .pending: return record.attempted == .pause ? "Pausing…" : "Resuming…"
        case .applied: return record.manual ? "Paused by hand" : "Paused by a rule"
        case .failed: return "Couldn't \(record.attempted == .pause ? "pause" : "resume"): \(record.error ?? "unknown problem")"
        }
    }
}
