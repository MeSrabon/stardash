import Foundation

/// One Ookla test server, as listed by speedtest.net. Holds enough to run a test without fetching the list again.
struct SpeedServer: Codable, Hashable, Identifiable {
    var id: String
    var sponsor: String
    /// The city, as Ookla writes it.
    var name: String
    var country: String
    /// host:port. Only servers that answer over https are kept, so this is always reached with https.
    var host: String
    /// The upload address from the list, kept as Ookla gave it.
    var url: String
    /// Kilometres from where speedtest.net places this Mac, when the list was fetched.
    var distance: Double?

    /// "Pacific Internet (S) · Singapore"
    var label: String { "\(sponsor) · \(name)" }
    var place: String { country.isEmpty ? name : "\(name), \(country)" }
    /// The folder the test files live in.
    var base: String { "https://\(host)/speedtest" }
}

/// What the test from this Mac measures against. The router test always uses its own server.
enum SpeedServerChoice: Codable, Hashable {
    case cloudflare
    /// Pings the nearest Ookla servers at the start of each run and uses the quickest.
    case auto
    case ookla(SpeedServer)

    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .auto: return "Auto · nearest Ookla server"
        case .ookla(let server): return server.label
        }
    }

    /// The saved choice. Demo mode starts on Cloudflare so a real server near the owner never shows.
    static var saved: SpeedServerChoice {
        guard !Demo.on, let data = UserDefaults.standard.data(forKey: "speedServer"),
              let choice = try? JSONDecoder().decode(SpeedServerChoice.self, from: data) else { return .cloudflare }
        return choice
    }

    static func save(_ choice: SpeedServerChoice) {
        guard !Demo.on else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: "speedServer")
    }
}

/// The public Ookla server list and the small requests used to pick from it.
/// Only called when the picker opens, when Auto runs, or during a test. Nothing about this Mac is sent:
/// the list is ranked by the address the request comes from, like any website would see.
enum Ookla {
    /// A plain agent string, so the requests don't carry the macOS version.
    static let agent = "StarDash"

    /// No cache, no cookies, and the plain agent string.
    static func config(timeout: Double = 15, connections: Int = 6) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": agent]
        config.httpMaximumConnectionsPerHost = connections
        config.httpCookieStorage = nil
        return config
    }

    static func session(timeout: Double = 15) -> URLSession {
        URLSession(configuration: config(timeout: timeout))
    }

    enum Failure: LocalizedError {
        case noList, noneAnswered
        var errorDescription: String? {
            switch self {
            case .noList: return "speedtest.net didn't send a server list"
            case .noneAnswered: return "None of the nearby Ookla servers answered"
            }
        }
    }

    /// Nearest first. With `search`, matches by city, sponsor or country, still sorted by distance.
    static func servers(search: String? = nil, limit: Int = 40) async throws -> [SpeedServer] {
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Demo.on {
            let q = query.lowercased()
            return demo.filter { q.isEmpty || "\($0.sponsor) \($0.name) \($0.country)".lowercased().contains(q) }
        }
        var parts = URLComponents(string: "https://www.speedtest.net/api/js/servers")!
        parts.queryItems = [URLQueryItem(name: "engine", value: "js"), URLQueryItem(name: "limit", value: String(limit))]
        if !query.isEmpty { parts.queryItems?.append(URLQueryItem(name: "search", value: query)) }
        guard let url = parts.url else { throw Failure.noList }
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.noList }
        return list.compactMap(parse).sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    private static func parse(_ row: [String: Any]) -> SpeedServer? {
        func text(_ key: String) -> String? {
            if let s = row[key] as? String { return s }
            if let n = row[key] as? NSNumber { return n.stringValue }
            return nil
        }
        // Servers without working https would need the app to allow plain http. About one in twenty; left out.
        guard let https = row["https_functional"], (https as? NSNumber)?.boolValue == true || (https as? String) == "1",
              let id = text("id"), let host = text("host"), !host.isEmpty else { return nil }
        return SpeedServer(id: id, sponsor: text("sponsor") ?? "Unknown", name: text("name") ?? "",
                           country: text("country") ?? "", host: host, url: text("url") ?? "",
                           distance: text("distance").flatMap(Double.init))
    }

    /// Round trip to the server in milliseconds, best of a few after a warm-up, or nil if it didn't answer.
    static func ping(_ server: SpeedServer, session: URLSession, tries: Int = 3) async -> Double? {
        var best: Double?
        for attempt in 0..<tries {
            guard let url = URL(string: "\(server.base)/latency.txt?r=\(UInt32.random(in: 0...UInt32.max))") else { return nil }
            let t0 = Date()
            guard let (_, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return best }
            // The first request pays for the TLS handshake.
            if attempt > 0 || tries == 1 { best = min(best ?? .infinity, Date().timeIntervalSince(t0) * 1000) }
        }
        return best
    }

    /// Auto: the quickest to answer of the ten nearest.
    static func nearest() async throws -> SpeedServer {
        let candidates = Array(try await servers(limit: 10).prefix(10))
        guard !candidates.isEmpty else { throw Failure.noList }
        let session = session(timeout: 4)
        defer { session.invalidateAndCancel() }
        let timed = await withTaskGroup(of: (SpeedServer, Double?).self) { group in
            for server in candidates { group.addTask { (server, await ping(server, session: session, tries: 2)) } }
            var all: [(SpeedServer, Double)] = []
            for await (server, ms) in group { if let ms { all.append((server, ms)) } }
            return all
        }
        guard let best = timed.min(by: { $0.1 < $1.1 }) else { throw Failure.noneAnswered }
        return best.0
    }

    /// Stand-ins for demo mode, near the demo location, so screenshots never show the owner's region.
    static let demo: [SpeedServer] = [
        ("Wave Broadband", "Seattle, WA", 3), ("Comcast", "Seattle, WA", 4), ("Ziply Fiber", "Seattle, WA", 6),
        ("T-Mobile", "Bellevue, WA", 11), ("Starry", "Tacoma, WA", 39), ("Spectrum", "Olympia, WA", 92),
        ("CenturyLink", "Portland, OR", 233), ("Shaw", "Vancouver, BC", 195),
    ].enumerated().map { i, s in
        let country = s.1.hasSuffix("BC") ? "Canada" : "United States"
        let host = "speedtest\(i + 1).example.net:8080"
        return SpeedServer(id: String(90000 + i), sponsor: s.0, name: s.1, country: country,
                           host: host, url: "http://\(host)/speedtest/upload.php", distance: Double(s.2))
    }
}
