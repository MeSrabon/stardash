import Foundation

/// Everything StarDash knows about the dish and router right now, as one JSON file for bug reports
/// and Starlink support. Built by reflection so new fields show up without touching this file.
enum DebugExport {
    @MainActor
    static func data(_ store: TelemetryStore) throws -> Data {
        let info = Bundle.main.infoDictionary
        var report: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "app": "StarDash \(info?["CFBundleShortVersionString"] as? String ?? "dev")",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        report["dish"] = plain(store.dish)
        report["dishError"] = store.dishError.map { "\($0)" }
        report["dishConfig"] = plain(store.dishConfig)
        report["router"] = plain(store.router)
        report["routerError"] = store.routerError.map { "\($0)" }
        if let map = store.map {
            report["obstructionMap"] = ["rows": map.rows, "cols": map.cols, "coverage": map.coverage,
                                        "minElevation": map.minElevation, "maxTheta": map.maxTheta]
        }
        report["events"] = store.events.prefix(200).map { event -> Any? in
            var fields = plain(event) as? [String: Any] ?? [:]
            fields["title"] = event.title
            return fields
        }
        report["alertHistory"] = store.alertLog.prefix(100).map { plain($0) }
        return try JSONSerialization.data(withJSONObject: report.compactMapValues { $0 },
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Turns any model value into something JSONSerialization accepts.
    static func plain(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.flatMap { plain($0.value) }
        }
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Double: return v.isFinite ? v : nil
        case let v as Float: return v.isFinite ? Double(v) : nil
        case let v as any BinaryInteger: return Int(v)
        case let v as Date: return ISO8601DateFormatter().string(from: v)
        case let v as Data: return v.count > 512 ? "\(v.count) bytes" : v.base64EncodedString()
        default: break
        }
        switch mirror.displayStyle {
        case .collection, .set:
            let items = mirror.children.compactMap { plain($0.value) }
            // Per-second rings and map cells would bury the useful parts.
            return items.count > 300 ? "\(items.count) values" : items
        case .dictionary:
            var out: [String: Any] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                if pair.count == 2, let v = plain(pair[1].value) { out["\(pair[0].value)"] = v }
            }
            return out
        case .struct, .class, .tuple, .enum:
            if mirror.children.isEmpty { return "\(value)" }
            var out: [String: Any] = [:]
            for (i, child) in mirror.children.enumerated() {
                if let v = plain(child.value) { out[child.label ?? "\(i)"] = v }
            }
            return out
        default:
            return "\(value)"
        }
    }
}
