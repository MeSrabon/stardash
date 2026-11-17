import Foundation

/// One hour of traffic and energy, built from the per-second samples. Kept far longer than the samples are.
struct HourBucket: Codable {
    /// Unix time divided by 3600.
    var hour: Int
    var down: Double = 0
    var up: Double = 0
    var wh: Double = 0
    var latencySum: Double = 0
    var latencyCount: Int = 0
    /// Seconds actually recorded in this hour, so gaps show up as gaps.
    var seconds: Int = 0

    var date: Date { Date(timeIntervalSince1970: Double(hour) * 3600) }
}

/// Running traffic total for one device in the current calendar month.
struct DeviceUsage: Codable, Identifiable {
    var id: String
    var name: String
    var down: Double = 0
    var up: Double = 0
    var lastDown: Double = 0
    var lastUp: Double = 0
}

struct UsageTotals {
    var down = 0.0, up = 0.0, wh = 0.0
    var seconds = 0
    var span = 1.0
    /// Share of the window StarDash was running and recording.
    var coverage: Double { min(1, Double(seconds) / span) }
}

extension TelemetryStore {
    static let hoursKept = 24 * 35

    func record(_ s: Sample) {
        samples.append(s)
        let hour = Int(s.t) / 3600
        if hours.last?.hour != hour {
            hours.append(HourBucket(hour: hour))
            if hours.count > Self.hoursKept { hours.removeFirst(hours.count - Self.hoursKept) }
        }
        let i = hours.count - 1
        hours[i].down += Double(s.down) / 8
        hours[i].up += Double(s.up) / 8
        hours[i].wh += Double(s.power) / 3600
        if s.drop < 1, s.latency > 0 {
            hours[i].latencySum += Double(s.latency)
            hours[i].latencyCount += 1
        }
        hours[i].seconds += 1
    }

    /// Hourly buckets that fall inside the last `hoursBack` hours.
    func hourly(_ hoursBack: Int) -> [HourBucket] {
        let cutoff = Int(Date().timeIntervalSince1970) / 3600 - hoursBack + 1
        return hours.filter { $0.hour >= cutoff }
    }

    func totals(_ hoursBack: Int) -> UsageTotals {
        var t = UsageTotals()
        t.span = Double(hoursBack) * 3600
        for b in hourly(hoursBack) {
            t.down += b.down
            t.up += b.up
            t.wh += b.wh
            t.seconds += b.seconds
        }
        return t
    }

    /// The router reports each device's bytes since it joined. Adding up the increases gives a monthly total
    /// that survives the device dropping off and coming back.
    func track(_ clients: [WifiClient]) {
        let month = Self.monthKey()
        if month != usageMonth {
            usageMonth = month
            deviceUsage = [:]
        }
        for c in clients where !c.isInfrastructure {
            let key = c.mac ?? c.name
            // The router counts from its own side: what it sent is what the device downloaded.
            var down = Double(c.txBytes), up = Double(c.rxBytes)
            if down + up == 0 {
                down = Double(c.downloadMB ?? 0) * 1e6
                up = Double(c.uploadMB ?? 0) * 1e6
            }
            var u = deviceUsage[key] ?? DeviceUsage(id: key, name: c.name, lastDown: down, lastUp: up)
            u.name = c.name
            u.down += down >= u.lastDown ? down - u.lastDown : down
            u.up += up >= u.lastUp ? up - u.lastUp : up
            u.lastDown = down
            u.lastUp = up
            deviceUsage[key] = u
        }
    }

    static func monthKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private struct StoredUsage: Codable {
        var hours: [HourBucket]
        var month: String
        var devices: [DeviceUsage]
    }

    func saveUsage(to dir: URL) {
        let stored = StoredUsage(hours: hours, month: usageMonth, devices: Array(deviceUsage.values))
        Task.detached(priority: .utility) {
            if let json = try? JSONEncoder().encode(stored) {
                try? json.write(to: dir.appendingPathComponent("usage.json"), options: .atomic)
            }
        }
    }

    func loadUsage(from dir: URL) {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("usage.json")),
           let stored = try? JSONDecoder().decode(StoredUsage.self, from: data) {
            hours = stored.hours
            usageMonth = stored.month
            deviceUsage = Dictionary(stored.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard hours.isEmpty else { return }
        // First run with this feature: rebuild what we can from the samples already on disk.
        let existing = samples
        samples = []
        for s in existing { record(s) }
    }
}

extension Fmt {
    /// Bytes as a number and unit, for big readouts.
    static func data(_ bytes: Double) -> String {
        if bytes >= 1e12 { return String(format: "%.2f TB", bytes / 1e12) }
        if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
        if bytes >= 1e6 { return String(format: "%.0f MB", bytes / 1e6) }
        return String(format: "%.0f KB", bytes / 1e3)
    }

    static func energy(_ wh: Double) -> String {
        wh >= 1000 ? String(format: "%.2f kWh", wh / 1000) : String(format: "%.0f Wh", wh)
    }
}
