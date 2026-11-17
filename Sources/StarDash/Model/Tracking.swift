import Foundation

// Things StarDash has to remember itself because the dish and router only report the present:
// how the sky map filled in, what the router's pings looked like over time, which alerts came and went,
// and how each device's signal and traffic moved.

/// The sky map as it stood at one moment, packed to a byte per cell.
struct MapFrame: Codable {
    var t: Double
    var rows: Int
    var cols: Int
    var maxTheta: Double
    var minElevation: Double
    /// 255 where the dish hasn't looked, otherwise clearness from 0 to 200.
    var cells: Data

    var date: Date { Date(timeIntervalSince1970: t) }

    init(_ map: ObstructionMap, at date: Date) {
        t = date.timeIntervalSince1970
        rows = map.rows
        cols = map.cols
        maxTheta = map.maxTheta
        minElevation = map.minElevation
        cells = Data(map.snr.map { $0 < 0 ? 255 : UInt8(min(200, max(0, $0 * 200))) })
    }

    var map: ObstructionMap {
        ObstructionMap(rows: rows, cols: cols, snr: cells.map { $0 == 255 ? -1 : Float($0) / 200 },
                       minElevation: minElevation, maxTheta: maxTheta)
    }

    var sampled: Int { cells.reduce(0) { $0 + ($1 == 255 ? 0 : 1) } }
}

extension ObstructionMap {
    init(rows: Int, cols: Int, snr: [Float], minElevation: Double, maxTheta: Double) {
        self.rows = rows
        self.cols = cols
        self.snr = snr
        self.minElevation = minElevation
        self.maxTheta = maxTheta
    }
}

/// One round of the router's own pings. A negative value means the router didn't report that leg.
struct PingSample {
    var t: Int32
    var dish: Float
    var pop: Float
    var internet: Float

    var date: Date { Date(timeIntervalSince1970: Double(t)) }
}

/// One alert from the moment it appeared until it cleared.
struct AlertRecord: Codable, Identifiable {
    var id: String { "\(name)-\(Int(start.timeIntervalSince1970))" }
    var name: String
    var source: String
    var start: Date
    var end: Date?
    /// Last time the alert was seen raised, so one left open by a quit can be closed honestly.
    var seen: Date

    var isActive: Bool { end == nil }
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

/// A device's signal and traffic at one moment.
struct DevicePoint {
    var t: Int32
    /// dBm, or 0 for wired devices.
    var signal: Float
    /// Bytes per second to and from the device.
    var down: Float
    var up: Float

    var date: Date { Date(timeIntervalSince1970: Double(t)) }
}

extension TelemetryStore {
    static let maxFrames = 288
    static let maxPings = 17_280
    static let maxDevicePoints = 720

    /// Keeps a frame when the map has changed and five minutes have passed, so a day fits in a few megabytes.
    func recordFrame(_ map: ObstructionMap) {
        let frame = MapFrame(map, at: Date())
        if let last = mapFrames.last {
            // A map with fewer sampled cells than before means the dish started over, which is worth a frame at once.
            let restarted = frame.sampled < last.sampled / 2
            guard restarted || frame.t - last.t >= 300, frame.cells != last.cells else { return }
        }
        mapFrames.append(frame)
        if mapFrames.count > Self.maxFrames { mapFrames.removeFirst(mapFrames.count - Self.maxFrames) }
    }

    func recordPing(_ r: RouterStatus) {
        let now = Int32(Date().timeIntervalSince1970)
        if let last = pings.last, now - last.t < 4 { return }
        func value(_ v: Double?) -> Float { v.map { Float($0) } ?? -1 }
        pings.append(PingSample(t: now, dish: value(r.dishLatencyMs), pop: value(r.popLatencyMs), internet: value(r.pingLatencyMs)))
        if pings.count > Self.maxPings { pings.removeFirst(pings.count - Self.maxPings) }
    }

    func recordDevices(_ clients: [WifiClient]) {
        let now = Date().timeIntervalSince1970
        for c in clients where !c.isInfrastructure {
            let key = c.id
            var down = Double(c.txBytes), up = Double(c.rxBytes)
            if down + up == 0 {
                down = Double(c.downloadMB ?? 0) * 1e6
                up = Double(c.uploadMB ?? 0) * 1e6
            }
            defer { deviceCounters[key] = (now, down, up) }
            guard let last = deviceCounters[key], now - last.t >= 3 else { continue }
            let dt = now - last.t
            // Counters restart when a device reconnects; a drop isn't negative traffic.
            let point = DevicePoint(t: Int32(now), signal: Float(c.isWireless ? c.signal ?? 0 : 0),
                                    down: Float(max(0, down - last.down) / dt), up: Float(max(0, up - last.up) / dt))
            var series = deviceSeries[key] ?? []
            series.append(point)
            if series.count > Self.maxDevicePoints { series.removeFirst(series.count - Self.maxDevicePoints) }
            deviceSeries[key] = series
        }
    }

    /// Opens a record for each alert that just appeared and closes the ones that cleared.
    func recordAlerts() {
        let now = Date()
        var active: [(String, String)] = []
        var reachable: Set<String> = []
        if let dish, dishError == nil {
            reachable.insert("Dish")
            active += dish.alerts.map { ($0, "Dish") }
        }
        if let router {
            reachable.insert("Router")
            active += router.alerts.map { ($0, "Router") }
        }
        var log = alertLog
        var changed = false
        for i in log.indices where log[i].isActive {
            if active.contains(where: { $0.0 == log[i].name && $0.1 == log[i].source }) {
                if now.timeIntervalSince(log[i].seen) > 60 { log[i].seen = now; changed = true }
            } else if reachable.contains(log[i].source) {
                // After a restart the alert may have cleared while StarDash wasn't looking.
                log[i].end = now.timeIntervalSince(log[i].seen) > 120 ? log[i].seen : now
                changed = true
            }
        }
        for (name, source) in active where !log.contains(where: { $0.isActive && $0.name == name && $0.source == source }) {
            log.insert(AlertRecord(name: name, source: source, start: now, seen: now), at: 0)
            changed = true
        }
        if changed { alertLog = Array(log.sorted { $0.start > $1.start }.prefix(300)) }
    }

    // MARK: Persistence

    func saveTracking(to dir: URL) {
        let frames = mapFrames, pingData = pings, alerts = alertLog
        Task.detached(priority: .utility) {
            if let data = try? PropertyListEncoder.binary.encode(frames) {
                try? data.write(to: dir.appendingPathComponent("mapframes.plist"), options: .atomic)
            }
            let raw = pingData.withUnsafeBufferPointer { Data(buffer: $0) }
            try? raw.write(to: dir.appendingPathComponent("pings.bin"), options: .atomic)
            if let json = try? JSONEncoder().encode(alerts) {
                try? json.write(to: dir.appendingPathComponent("alerts.json"), options: .atomic)
            }
        }
    }

    func loadTracking(from dir: URL) {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("mapframes.plist")),
           let frames = try? PropertyListDecoder().decode([MapFrame].self, from: data) {
            mapFrames = frames.filter { $0.cells.count == $0.rows * $0.cols }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("pings.bin")),
           data.count % MemoryLayout<PingSample>.stride == 0 {
            let cutoff = Int32(Date().timeIntervalSince1970) - 86_400
            let all: [PingSample] = data.withUnsafeBytes { Array($0.bindMemory(to: PingSample.self)) }
            pings = all.filter { $0.t >= cutoff }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("alerts.json")),
           let alerts = try? JSONDecoder().decode([AlertRecord].self, from: data) {
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            alertLog = alerts.filter { $0.isActive || $0.start >= cutoff }
        }
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

// MARK: What the router remembers

extension TelemetryStore {
    /// The router keeps twelve hours of its own once-a-second ping to the internet. Reading it fills in
    /// the stretches when StarDash wasn't running.
    func backfillPings(_ client: GRPCWebClient) async {
        guard let response = try? await client.call(1007, timeout: 10), let body = response.message(3006) else { return }
        let current = body.int(1) ?? 0
        let ring = body.floats(1002)
        guard current > 0, !ring.isEmpty else { return }
        let valid = min(current, ring.count)
        let now = Int32(Date().timeIntervalSince1970)
        var have = Set(pings.map { $0.t / 5 })
        var added: [PingSample] = []
        // One point every five seconds, matching what StarDash records live.
        for back in stride(from: valid - 1, through: 0, by: -5) {
            let value = ring[(current - 1 - back) % ring.count]
            let t = now - Int32(back)
            guard value.isFinite, value > 0, !have.contains(t / 5) else { continue }
            have.insert(t / 5)
            added.append(PingSample(t: t, dish: -1, pop: -1, internet: value))
        }
        guard !added.isEmpty else { return }
        let merged = (pings + added).sorted { $0.t < $1.t }
        pings = Array(merged.suffix(Self.maxPings))
    }

    /// The router's own record of one device: fifteen minutes of traffic and signal, a point a second.
    /// It lives on the router, so it's there even right after StarDash starts.
    func clientHistory(_ device: WifiClient) async -> [DevicePoint] {
        var request = ProtoWriter.field(1, body: Array((device.mac ?? "").utf8))
        if let id = device.clientID { request += [16] + ProtoWriter.varint(id) }
        guard let response = try? await routerClient.call(3015, body: request, timeout: 6),
              let body = response.message(3015) else { return [] }
        let current = body.int(1) ?? 0
        let down = body.floats(2), up = body.floats(3)
        let signal = body.bytes(6) ?? []
        let n = min(down.count, up.count)
        guard current > 0, n > 0 else { return [] }
        let valid = min(current, n)
        let now = Int32(Date().timeIntervalSince1970)
        return (0..<valid).map { k in
            let i = (current - valid + k) % n
            let dBm = i < signal.count ? Float(Int8(bitPattern: signal[i])) : 0
            // Megabits a second on the router's side: what it sent is what the device downloaded.
            return DevicePoint(t: now - Int32(valid - 1 - k), signal: dBm, down: down[i] * 125_000, up: up[i] * 125_000)
        }
    }
}
