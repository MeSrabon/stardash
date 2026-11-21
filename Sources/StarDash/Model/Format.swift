import Foundation

enum Fmt {
    static let missing = "--"

    static func rate(_ bps: Double?, bytes: Bool, compact: Bool = false) -> String {
        guard let bps, bps.isFinite else { return missing }
        if bytes {
            let v = bps / 8
            if v >= 1_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
            if v >= 1_000 { return String(format: "%.0f KB/s", v / 1_000) }
            return String(format: "%.0f B/s", v)
        }
        if bps >= 1_000_000_000 { return String(format: "%.2f Gbps", bps / 1_000_000_000) }
        if bps >= 1_000_000 { return String(format: bps >= 100_000_000 ? "%.0f Mbps" : "%.1f Mbps", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f kbps", bps / 1_000) }
        return String(format: "%.0f bps", bps)
    }

    static func ms(_ v: Double?) -> String {
        guard let v, v.isFinite else { return missing }
        return String(format: "%.0f ms", v)
    }

    static func percent(_ fraction: Double?, digits: Int = 1) -> String {
        guard let fraction, fraction.isFinite else { return missing }
        return String(format: "%.\(digits)f%%", fraction * 100)
    }

    static func watts(_ v: Double?) -> String {
        guard let v, v.isFinite, v > 0 else { return missing }
        return String(format: "%.0f W", v)
    }

    static func degrees(_ v: Double?, digits: Int = 1) -> String {
        guard let v, v.isFinite else { return missing }
        return String(format: "%.\(digits)f°", v)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return missing }
        if seconds < 1 { return String(format: "%.1f s", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }

    static func bytes(_ b: UInt64) -> String {
        let v = Double(b)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9 { return String(format: "%.2f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(b) B"
    }

    static func megabytes(_ mb: Int?) -> String {
        guard let mb else { return missing }
        return bytes(UInt64(max(0, mb)) * 1_000_000)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// "9:18 PM", for times that are obviously today.
    static let shortClock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Safe in a file name: "2026-11-19 0412".
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func compass(_ azimuth: Double?) -> String {
        guard let azimuth, azimuth.isFinite else { return "" }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = (azimuth.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized / 22.5).rounded()) % 16]
    }
}

enum LocalNetwork {
    /// IPv4 addresses assigned to this Mac, for tagging "This Mac" in the client list.
    static func ipv4Addresses() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.insert(String(cString: host))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}
