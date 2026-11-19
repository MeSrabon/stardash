import Foundation

// Field numbers come from the device's own protoset (api_version 44 dish, 135 router).
// Every read is optional: firmware adds and drops fields without notice.

// MARK: - Dish

enum LinkState: Equatable {
    case online
    case degraded(String)
    case offline(String)
    case unreachable

    var title: String {
        switch self {
        case .online: return "Online"
        case .degraded(let why): return why
        case .offline(let why): return why
        case .unreachable: return "Dish unreachable"
        }
    }

    var isUp: Bool {
        switch self {
        case .online, .degraded: return true
        default: return false
        }
    }
}

struct ObstructionStats {
    var fraction: Double?
    var timeObstructed: Double?
    var validSeconds: Double?
    var currentlyObstructed = false
    var avgProlongedDuration: Double?
    var avgProlongedInterval: Double?
    var patchesValid: Int?
}

struct Alignment {
    var azimuth: Double?
    var elevation: Double?
    var desiredAzimuth: Double?
    var desiredElevation: Double?
    var tilt: Double?
    var uncertainty: Double?
    var converged: Bool?
    var hasActuators: Bool?

    /// Signed degrees to rotate (positive = clockwise seen from above).
    var azimuthError: Double? {
        guard let a = azimuth, let d = desiredAzimuth else { return nil }
        var diff = (d - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    var elevationError: Double? {
        guard let e = elevation, let d = desiredElevation else { return nil }
        return d - e
    }
}

struct DishStatus {
    var id: String?
    var hardwareVersion: String?
    var softwareVersion: String?
    var countryCode: String?
    var bootCount: Int?
    var uptime: Int?

    var latencyMs: Double?
    var dropRate: Double
    var downBps: Double
    var upBps: Double

    var outageCause: Int?
    var alerts: [String]
    var obstruction: ObstructionStats
    var alignment: Alignment

    var gpsValid: Bool?
    var gpsSats: Int?
    var ethSpeedMbps: Int?
    var snrAboveNoiseFloor: Bool
    var snrPersistentlyLow: Bool
    var readyStates: [(String, Bool)]
    var classOfService: Int?
    var mobilityClass: Int?
    var softwareUpdateState: Int?
    var softwareUpdateProgress: Double?
    var rebootReady: Bool
    var disablementCode: Int?
    var dlRestricted: Int?
    var ulRestricted: Int?
    var initDurations: [(String, Int)]
    var connectedRouters: [String]
    var stowRequested: Bool

    init(_ m: ProtoMessage) {
        let info = m.message(1) ?? .empty
        id = info.string(1)
        hardwareVersion = info.string(2)
        softwareVersion = info.string(3)
        countryCode = info.string(4)
        bootCount = info.int(8)
        uptime = m.message(2)?.int(1)

        latencyMs = m.float(1009)
        dropRate = m.float(1003) ?? 0
        downBps = m.float(1007) ?? 0
        upBps = m.float(1008) ?? 0

        outageCause = m.message(1014).map { $0.int(1) ?? 0 }

        let a = m.message(1005) ?? .empty
        alerts = DishStatus.alertNames.compactMap { a.bool($0.0) ? $0.1 : nil }

        let o = m.message(1004) ?? .empty
        obstruction = ObstructionStats(
            fraction: o.float(1) ?? (m.has(1004) ? 0 : nil),
            timeObstructed: o.float(9),
            validSeconds: o.float(4),
            currentlyObstructed: o.bool(5),
            avgProlongedDuration: o.float(6),
            avgProlongedInterval: o.float(7),
            patchesValid: o.int(10)
        )

        let al = m.message(1027) ?? .empty
        alignment = Alignment(
            azimuth: al.float(4) ?? m.float(1011),
            elevation: al.float(5) ?? m.float(1012),
            desiredAzimuth: al.float(8),
            desiredElevation: al.float(9),
            tilt: al.float(3),
            uncertainty: al.float(7),
            converged: al.int(6).map { $0 == 2 },
            hasActuators: (al.int(1) ?? m.int(1023)).flatMap { $0 == 0 ? nil : $0 == 1 }
        )

        let gps = m.message(1015)
        gpsValid = gps?.bool(1)
        gpsSats = gps?.int(2)
        ethSpeedMbps = m.int(1016)
        snrAboveNoiseFloor = m.bool(1018)
        snrPersistentlyLow = m.bool(1022)

        let r = m.message(1019) ?? .empty
        readyStates = [("SCP", 2), ("L1/L2", 3), ("xPHY", 4), ("AAP", 5), ("RF", 6)].map { ($0.0, r.bool($0.1)) }

        classOfService = m.int(1020)
        mobilityClass = m.int(1017)
        let sw = m.message(1026)
        softwareUpdateState = sw?.int(1) ?? m.int(1021)
        softwareUpdateProgress = sw?.float(2)
        rebootReady = m.bool(1030)
        disablementCode = m.int(1024)
        dlRestricted = m.int(1044)
        ulRestricted = m.int(1045)

        let d = m.message(1028) ?? .empty
        initDurations = [
            ("GPS valid", 6), ("RF ready", 9), ("Burst detected", 2), ("Network entry", 7),
            ("First control plane", 4), ("Network schedule", 8), ("First PoP ping", 5),
            ("Stable connection", 10), ("Attitude initialized", 1), ("EKF converged", 3),
        ].compactMap { pair in d.int(pair.1).map { (pair.0, $0) } }

        connectedRouters = m.strings(1040)
        stowRequested = m.bool(1010)
    }

    static let alertNames: [(Int, String)] = [
        (1, "Motors stuck"), (2, "Thermal shutdown"), (3, "Thermal throttling"),
        (4, "Unexpected location"), (5, "Mast not near vertical"), (6, "Slow Ethernet (10 Mbps)"),
        (18, "Slow Ethernet (100 Mbps)"), (8, "Install pending"), (9, "Heating (snow melt)"),
        (10, "Power supply thermal throttling"), (11, "Power save idle"),
        (16, "Low motor current"), (17, "Signal lower than predicted"),
        (19, "Obstruction map reset"), (20, "Water detected in dish"),
        (21, "Water detected in router"), (22, "Router port slow"), (23, "No Ethernet link"),
    ]

    /// Alerts that don't mean anything is wrong right now.
    static let benignAlerts: Set<String> = ["Obstruction map reset", "Heating (snow melt)", "Power save idle", "Install pending"]

    var state: LinkState {
        if let cause = outageCause {
            return .offline(Names.outageCause(cause))
        }
        if let code = disablementCode, code > 1 {
            return .offline(Names.disablement(code))
        }
        if obstruction.currentlyObstructed { return .degraded("Obstructed") }
        if let serious = alerts.first(where: { !DishStatus.benignAlerts.contains($0) }) {
            return .degraded(serious)
        }
        if dropRate >= 0.05 { return .degraded("Packet loss") }
        return .online
    }

    var modelName: String { Names.dishModel(hardwareVersion) }
}

struct LinkEvent: Identifiable, Equatable {
    var id: String { "\(reason)-\(Int(start.timeIntervalSince1970 * 1000))" }
    var reason: Int
    var severity: Int
    var start: Date
    var duration: TimeInterval
    var source: String
    /// What changed, for events StarDash notices itself (which device, which addresses).
    var detail: String? = nil

    var title: String { Names.eventReason(reason) }
    var isOutage: Bool { (1...11).contains(reason) || reason == 19 || reason == 50 }
}

struct DishHistory {
    var current: Int
    var latency: [Float]
    var drop: [Float]
    var down: [Float]
    var up: [Float]
    var power: [Float]
    var events: [LinkEvent]

    init(_ m: ProtoMessage) {
        let cur = m.int(1) ?? 0
        current = cur

        func unroll(_ ring: [Float]) -> [Float] {
            let n = ring.count
            guard n > 0, cur > 0 else { return [] }
            let valid = min(cur, n)
            return ((cur - valid)..<cur).map { ring[$0 % n] }
        }

        drop = unroll(m.floats(1001))
        latency = unroll(m.floats(1002))
        down = unroll(m.floats(1003))
        up = unroll(m.floats(1004))
        let p = m.floats(1010)
        power = unroll(p.isEmpty ? m.floats(1012) : p)

        var list: [LinkEvent] = []
        if let log = m.message(1011) {
            for e in log.messages(1) {
                guard let startNs = e.int(3) else { continue }
                let id = e.string(12) ?? ""
                list.append(LinkEvent(
                    reason: e.int(2) ?? 0,
                    severity: e.int(1) ?? 0,
                    start: Date(timeIntervalSince1970: Double(startNs) / 1e9),
                    duration: Double(e.uint(4) ?? 0) / 1e9,
                    source: id.hasPrefix("Router") ? "Router" : "Dish"
                ))
            }
        }
        if list.isEmpty {
            // Older firmware: outages only, stamped in GPS time.
            let gpsToUnix = 315_964_800.0 - 18
            for o in m.messages(1009) {
                guard let startNs = o.int(2) else { continue }
                let cause = o.int(1) ?? 0
                list.append(LinkEvent(
                    reason: Names.reasonForOutageCause(cause),
                    severity: 1,
                    start: Date(timeIntervalSince1970: Double(startNs) / 1e9 + gpsToUnix),
                    duration: Double(o.uint(3) ?? 0) / 1e9,
                    source: "Dish"
                ))
            }
        }
        events = list.sorted { $0.start > $1.start }
    }
}

struct ObstructionMap {
    var rows: Int
    var cols: Int
    var snr: [Float]
    var minElevation: Double
    var maxTheta: Double

    init?(_ m: ProtoMessage) {
        rows = m.int(1) ?? 0
        cols = m.int(2) ?? 0
        snr = m.floats(3)
        minElevation = m.float(4) ?? 10
        maxTheta = m.float(5) ?? 80
        guard rows > 0, cols > 0, snr.count == rows * cols else { return nil }
    }

    /// Share of sampled sky cells that are obstructed.
    var sampledFraction: Double {
        let sampled = snr.filter { $0 >= 0 }
        guard !sampled.isEmpty else { return 0 }
        return Double(sampled.filter { $0 < 0.5 }.count) / Double(sampled.count)
    }

    var coverage: Double {
        // Cells inside the inscribed circle are the ones the dish can ever sample.
        let total = Double.pi * Double(rows) * Double(cols) / 4
        return min(1, Double(snr.filter { $0 >= 0 }.count) / total)
    }
}

// MARK: - Router

struct WifiClient: Identifiable {
    var id: String { mac ?? name }
    var name: String
    var mac: String?
    var ip: String?
    var signal: Double?
    var snr: Double?
    var iface: Int
    var role: Int
    var rxRateMbps: Double?
    var txRateMbps: Double?
    var rxBytes: UInt64
    var txBytes: UInt64
    var associatedSeconds: Int?
    var channelWidth: Int?
    var uploadMB: Int?
    var downloadMB: Int?
    var blocked: Bool
    /// The router's own number for this device, which its history lookup wants.
    var clientID: UInt64?

    init(_ m: ProtoMessage) {
        clientID = m.uint(43)
        name = m.string(31) ?? m.string(1) ?? "Unnamed device"
        mac = m.string(2)
        ip = m.string(3)
        signal = m.float(4)
        snr = m.float(10)
        iface = m.int(9) ?? 0
        role = m.int(14) ?? 0
        let rx = m.message(5) ?? .empty
        let tx = m.message(6) ?? .empty
        rxRateMbps = rx.uint(8).map(Double.init)
        txRateMbps = tx.uint(8).map(Double.init)
        rxBytes = rx.uint(1) ?? 0
        txBytes = tx.uint(1) ?? 0
        associatedSeconds = m.int(7)
        channelWidth = m.int(12)
        uploadMB = m.int(54)
        downloadMB = m.int(55)
        blocked = m.bool(42)
    }

    var ifaceName: String { Self.bandName(iface) }

    static func bandName(_ iface: Int) -> String {
        switch iface {
        case 1: return "Ethernet"
        case 2: return "2.4 GHz"
        case 3: return "5 GHz"
        case 4: return "5 GHz high"
        default: return "Unknown"
        }
    }

    var isWireless: Bool { iface >= 2 }
    var isInfrastructure: Bool { role == 2 || role == 3 }
}

struct RouterStatus {
    var id: String?
    var hardwareVersion: String?
    var softwareVersion: String?
    var bootCount: Int?
    var uptime: Int?
    var wanIPv4: String?
    var publicIPv4: String?
    var wanIPv6: [String]
    var pingLatencyMs: Double?
    var popLatencyMs: Double?
    var dishLatencyMs: Double?
    var popDropRate5m: Double?
    var dishDropRate5m: Double?
    var noWanLink: Bool
    var bypassMode: Bool
    var ssids: [(ssid: String, band: String)]
    var clients: [WifiClient]
    var alerts: [String]

    init(_ m: ProtoMessage) {
        let info = m.message(3) ?? .empty
        id = info.string(1)
        hardwareVersion = info.string(2)
        softwareVersion = info.string(3)
        bootCount = info.int(8)
        uptime = m.message(4)?.int(1)
        wanIPv4 = m.string(1003)
        publicIPv4 = m.string(1036)
        wanIPv6 = m.strings(1017)
        pingLatencyMs = m.float(1005)
        popLatencyMs = m.float(1015)
        dishLatencyMs = m.float(1013)
        popDropRate5m = m.float(1020)
        dishDropRate5m = m.float(1018)
        noWanLink = m.bool(1035)

        let config = m.message(2000) ?? .empty
        bypassMode = config.bool(31)
        var seen: [(String, String)] = []
        for network in config.messages(1100) {
            for bss in network.messages(1007) {
                guard let ssid = bss.string(1005) else { continue }
                let band: String
                switch bss.int(1011) ?? 0 {
                case 2: band = "2.4 GHz"
                case 5: band = "5 GHz"
                case 6: band = "5 GHz high"
                default: band = ""
                }
                seen.append((ssid, band))
            }
        }
        ssids = seen.map { (ssid: $0.0, band: $0.1) }
        clients = m.messages(3000).map(WifiClient.init)

        let a = m.message(1010) ?? .empty
        alerts = [
            (1, "Router thermal throttling"), (4, "LAN Ethernet slow (10 Mbps)"),
            (5, "LAN Ethernet slow (100 Mbps)"), (21, "High cable ping drop rate"),
            (10, "Poor WAN Ethernet connection"), (11, "Mesh topology changing often"),
            (12, "Unreliable mesh backhaul"), (15, "Dish unreachable over PoE"),
        ].compactMap { a.bool($0.0) ? $0.1 : nil }
    }

    var modelName: String { Names.routerModel(hardwareVersion) }
}

struct RadioStat: Identifiable {
    var id: Int { band }
    var band: Int
    var rxBytes: UInt64
    var txBytes: UInt64
    var rxErrors: UInt64
    var temperature: Double?
    var dutyCycle: Int?

    init(_ m: ProtoMessage) {
        band = m.int(1) ?? 0
        rxBytes = m.message(2)?.uint(1) ?? 0
        rxErrors = m.message(2)?.uint(3) ?? 0
        txBytes = m.message(3)?.uint(1) ?? 0
        let t = m.message(4)
        temperature = t?.float(3) ?? t?.uint(2).map(Double.init)
        dutyCycle = t?.int(5)
    }

    var bandName: String {
        switch band {
        case 2: return "2.4 GHz"
        case 5: return "5 GHz"
        case 6: return "5 GHz high"
        default: return "Radio \(band)"
        }
    }
}

struct NetInterface: Identifiable {
    var id: String { name }
    var name: String
    var up: Bool
    var mac: String?
    var ipv4: [String]
    var rxBytes: UInt64
    var txBytes: UInt64
    var kind: String
    var detail: String?

    init(_ m: ProtoMessage) {
        name = m.string(1) ?? "?"
        up = m.bool(4)
        mac = m.string(5)
        ipv4 = m.strings(6)
        rxBytes = m.message(2)?.uint(1) ?? 0
        txBytes = m.message(3)?.uint(1) ?? 0
        if let eth = m.message(1000) {
            kind = "Ethernet"
            if eth.bool(1) {
                let duplex = eth.int(4) == 2 ? "full duplex" : eth.int(4) == 1 ? "half duplex" : ""
                detail = ["\(eth.int(2) ?? 0) Mbps", duplex].filter { !$0.isEmpty }.joined(separator: ", ")
            } else {
                detail = "No link"
            }
        } else if let wifi = m.message(1001) {
            kind = "Wi-Fi"
            detail = wifi.int(3).map { "Channel \($0)" }
        } else if let bridge = m.message(1002) {
            kind = "Bridge"
            let members = bridge.strings(1)
            detail = members.isEmpty ? nil : members.joined(separator: ", ")
        } else {
            kind = "Interface"
            detail = nil
        }
    }
}

// MARK: - Names

enum Names {
    static func dishModel(_ hw: String?) -> String {
        guard let hw = hw?.lowercased() else { return "Starlink" }
        if hw.hasPrefix("mini") { return "Starlink Mini" }
        if hw.hasPrefix("hp_flat") || hw.hasPrefix("hp1_flat") { return "Flat High Performance" }
        if hw.hasPrefix("hp") { return "High Performance" }
        if hw.hasPrefix("rev4") { return "Standard" }
        if hw.hasPrefix("rev3") { return "Standard Actuated" }
        if hw.hasPrefix("rev2") || hw.hasPrefix("rev1") { return "Standard Circular" }
        return "Starlink"
    }

    static func routerModel(_ hw: String?) -> String {
        guard let hw = hw?.lowercased() else { return "Router" }
        switch hw {
        case "v1": return "Gen 1 Router"
        case "v2": return "Gen 2 Router"
        case "v3": return "Gen 3 Router"
        default: return "Starlink Router (\(hw))"
        }
    }

    static func outageCause(_ c: Int) -> String {
        switch c {
        case 1: return "Booting"
        case 2: return "Stowed"
        case 3: return "Thermal shutdown"
        case 4: return "No schedule"
        case 5: return "No satellites"
        case 6: return "Obstructed"
        case 7: return "No downlink"
        case 8: return "No pings"
        case 9: return "Actuator moving"
        case 10: return "Cable test"
        case 11: return "Sleeping"
        case 13: return "Searching sky"
        case 14: return "RF inhibited"
        default: return "Offline"
        }
    }

    static func reasonForOutageCause(_ c: Int) -> Int {
        switch c {
        case 1: return 2
        case 2: return 3
        case 3: return 4
        case 4: return 5
        case 5: return 6
        case 6: return 7
        case 7: return 8
        case 8: return 9
        case 11: return 10
        case 13: return 19
        case 14: return 50
        default: return 1
        }
    }

    static func eventReason(_ r: Int) -> String {
        switch r {
        case 1: return "Outage"
        case 2: return "Booting"
        case 3: return "Stowed"
        case 4: return "Thermal shutdown"
        case 5: return "No schedule"
        case 6: return "No satellites"
        case 7: return "Obstructed"
        case 8: return "No downlink"
        case 9: return "No pings"
        case 10: return "Sleeping"
        case 11: return "Moving while not allowed"
        case 12: return "High downlink packet loss"
        case 13: return "Router factory reset"
        case 14: return "Router reboot"
        case 15: return "Router power cycle"
        case 16: return "Router config update"
        case 17: return "Router software update"
        case 18: return "Router thermal throttling"
        case 19: return "Searching sky"
        case 20: return "Router reboot (config)"
        case 21: return "Public IPv4 changed"
        case 22: return "Low signal (rain)"
        case 23: return "No Ethernet link"
        case 24, 25: return "Slow Ethernet link"
        case 26: return "PoP IPv4 ping drop"
        case 27: return "PoP IPv6 ping drop"
        case 28: return "LAN Ethernet packet loss"
        case 29: return "WAN Ethernet packet loss"
        case 30: return "DHCP server failed"
        case 31: return "DHCP pool exhausted"
        case 36, 37: return "Max wireless clients"
        case 38: return "Mesh topology unstable"
        case 39: return "Connection table full"
        case 40: return "Dish ping drop"
        case 42: return "Client reconnecting often"
        case 43: return "Client switching band"
        case 44: return "Client switching node"
        case 45: return "Mesh connection changing"
        case 46: return "Weak mesh backhaul"
        case 47: return "Crowded Wi-Fi channel"
        case 48: return "Client opening many connections"
        case 49: return "LAN Ethernet low speed"
        case 50: return "RF inhibited"
        case LinkEvent.publicIPChanged: return "Public IP changed"
        case LinkEvent.bandSwitch: return "Switched Wi-Fi band"
        case 51: return "Mesh backhaul flapping"
        default: return "Event \(r)"
        }
    }

    static func severity(_ s: Int) -> String {
        switch s {
        case 1: return "Warning"
        case 2: return "Caution"
        case 3: return "Advisory"
        default: return "Info"
        }
    }

    static func disablement(_ c: Int) -> String {
        switch c {
        case 2: return "No active account"
        case 3: return "Too far from service address"
        case 4: return "In ocean"
        case 6: return "Blocked country"
        case 7: return "Data overage"
        case 8: return "Cell disabled"
        case 10: return "Roaming restricted"
        case 11: return "Unknown location"
        case 12: return "Account disabled"
        case 13: return "Unsupported firmware"
        case 14: return "Moving too fast"
        case 15: return "Aviation flyover limits"
        default: return "Service disabled"
        }
    }

    static func softwareUpdate(_ s: Int?) -> String {
        switch s {
        case 1: return "Up to date"
        case 2: return "Downloading update"
        case 3: return "Checking update"
        case 4: return "Installing update"
        case 5: return "Verifying update"
        case 6: return "Reboot required"
        case 7: return "Updates disabled"
        case 8: return "Update failed"
        default: return "Unknown"
        }
    }

    static func classOfService(_ c: Int?) -> String? {
        switch c {
        case 1: return "Consumer"
        case 2: return "Business"
        case 3: return "Business Plus"
        case 4: return "Aviation"
        default: return nil
        }
    }

    static func mobility(_ c: Int?) -> String {
        switch c {
        case 1: return "Nomadic"
        case 2: return "Mobile"
        default: return "Stationary"
        }
    }

    static func rateLimit(_ r: Int?) -> String? {
        switch r {
        case 1: return "No limit"
        case 2: return "Limited by plan policy"
        case 3: return "Custom user limit"
        case 5: return "Limited (data overage)"
        case 6: return "Low speed policy"
        default: return nil
        }
    }

    static func flag(_ country: String?) -> String {
        guard let c = country?.uppercased(), c.count == 2 else { return "" }
        return String(String.UnicodeScalarView(c.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }
}
