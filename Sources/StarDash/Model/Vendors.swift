import Foundation
import Observation

/// Who made a device, from the first half of its hardware address.
/// The public IEEE list is downloaded once and kept on disk; no address ever leaves this Mac.
@MainActor
@Observable
final class Vendors {
    static let shared = Vendors()

    private var table: [String: String] = [:]
    @ObservationIgnored private var loading = false

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("vendors.tsv")
    }

    /// Phones and laptops often show the network a made-up address, which belongs to no maker.
    static func isPrivate(_ mac: String) -> Bool {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count >= 2, let second = hex.dropFirst().first else { return false }
        return "26AEae".contains(second)
    }

    func name(for mac: String?) -> String? {
        guard let mac else { return nil }
        if Self.isPrivate(mac) { return "Private address" }
        let prefix = String(mac.filter(\.isHexDigit).prefix(6)).uppercased()
        return prefix.count == 6 ? table[prefix] : nil
    }

    /// Loads the list from disk, fetching it first when it's missing or two months old.
    func loadIfNeeded() {
        guard table.isEmpty, !loading else { return }
        loading = true
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            var text = try? String(contentsOf: url, encoding: .utf8)
            let age = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if text == nil || age > 60 * 86_400, let fresh = await Self.download() {
                text = fresh
                try? fresh.write(to: url, atomically: true, encoding: .utf8)
            }
            var parsed: [String: String] = [:]
            for line in (text ?? "").split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                parsed[String(line[..<tab])] = String(line[line.index(after: tab)...])
            }
            let result = parsed
            await MainActor.run {
                self.table = result
                self.loading = false
            }
        }
    }

    /// Fetches the IEEE registry and boils it down to "prefix<tab>name" lines.
    private nonisolated static func download() async -> String? {
        guard let url = URL(string: "https://standards-oui.ieee.org/oui/oui.csv") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("StarDash", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let csv = String(data: data, encoding: .utf8) else { return nil }
        var lines: [String] = []
        for row in csv.split(whereSeparator: \.isNewline).dropFirst() {
            // Registry,Assignment,"Organization Name",Address
            let parts = row.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1].count == 6 else { continue }
            var rest = parts[2]
            var name: String
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var out = ""
                var i = rest.startIndex
                while i < rest.endIndex {
                    if rest[i] == "\"" {
                        let next = rest.index(after: i)
                        if next < rest.endIndex, rest[next] == "\"" { out.append("\""); i = rest.index(after: next); continue }
                        break
                    }
                    out.append(rest[i])
                    i = rest.index(after: i)
                }
                name = out
            } else {
                name = String(rest.prefix { $0 != "," })
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { lines.append("\(parts[1].uppercased())\t\(name)") }
        }
        return lines.count > 1000 ? lines.joined(separator: "\n") : nil
    }
}
