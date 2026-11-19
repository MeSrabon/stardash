import Foundation

// Talks to the user's own starlink.com account: the same calls the Starlink website and app make.
// The protocol was learned from Dishylink (MIT, github.com/DaveyHert/dishylink), mainly
// cloud/starlinkCloudHandler.ts, core/routerConfigUpdate.ts and core/routerClientUpdate.ts.
//
// None of this is a published API. It can change whenever Starlink changes its website.

enum CloudError: LocalizedError {
    /// No session, or Starlink no longer accepts it.
    case signedOut
    /// The account hasn't named a router yet. Not a fault; it fills in once the router checks in.
    case noRouter
    /// Stopped before anything was sent.
    case refused(String)
    case http(Int)
    /// The router answered through Starlink with a gRPC status.
    case device(Int, String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Your Starlink session has ended. Sign in again in Settings."
        case .noRouter: return "Starlink hasn't reported your router yet. Try again once it checks in."
        case .refused(let why): return why
        case .http(let code): return "Starlink answered with HTTP \(code)."
        case .device(5, _): return "Starlink couldn't reach the router just now. Nothing was changed. Try again in a minute."
        case .device(let code, let message):
            return message.isEmpty ? "The router said no (status \(code))." : "The router said no: \(message)"
        case .malformed(let what): return "Starlink sent \(what) StarDash couldn't read. Nothing was changed."
        }
    }
}

// MARK: Read models

struct CloudProfile {
    var name: String?
    var email: String?
    var accountNumber: String?
    var serviceLine: String?
}

struct BillingCycle: Identifiable {
    var id: Int
    var start: Date
    var end: Date
    var totalGB: Double
    /// One figure per day of the cycle, in GB.
    var daily: [Double]
}

struct BillingUsage {
    /// Oldest first, the way Starlink sends them.
    var cycles: [BillingCycle]
    var limitGB: Double?
    var bucketName: String?

    /// Starlink uses 100,000 GB to mean no cap.
    var unlimited: Bool { (limitGB ?? 0) >= 100_000 }

    /// Day of the month the current cycle began on, for rules that follow the bill.
    var billingDay: Int? {
        guard let start = cycles.last?.start else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.component(.day, from: start)
    }
}

struct RouterCloudSettings {
    struct Network: Identifiable {
        var id: String { ssid }
        var ssid: String
        var bands: [String]
        var guest: Bool
        var secured: Bool
    }

    struct MeshNode: Identifiable {
        var id: String
        var name: String
        var trusted: Bool
        var auth: String
        var hardware: String?
    }

    var networks: [Network]
    var nameservers: [String]
    /// Some kits can't use custom DNS at all. The router says so in its config.
    var customDNSAllowed: Bool
    var mesh: [MeshNode]
}

// MARK: Client

actor StarlinkCloud {
    private static let authURL = URL(string: "https://api.starlink.com/auth-rp/auth/user")!
    private static let api = "https://starlink.com/api"
    private static let handleURL = URL(string: "https://starlink.com/api/SpaceX.API.Device.Device/Handle")!
    /// The Access token is short-lived. Refresh at most this often.
    private static let tokenLife: TimeInterval = 60
    /// Account and service line numbers hardly ever change.
    private static let idsLife: TimeInterval = 300
    /// A week, in minutes. A pause is a block schedule covering all of it.
    static let weekMinutes: UInt64 = 7 * 24 * 60
    static let permanentGroup = "_permanent"

    private let session: URLSession
    private var token: (cookie: String, at: Date)?
    private var refreshing: Task<String, Error>?
    private var ids: (account: String, serviceLine: String, at: Date)?
    private var controller: (id: String, at: Date)?
    /// Bumped on sign-in and sign-out, so a refresh already in flight can't write an old session back.
    private var generation = 0
    /// Every write rewrites part of the router's config, so they go one at a time.
    private var tail: Task<Void, Never>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        // Cookies are set by hand from the keychain copy. Nothing goes to a shared cookie jar.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: Session

    /// Stores a fresh session from the sign-in window and checks it works.
    func connect(_ cookie: String) async throws -> CloudProfile {
        guard cookie.contains("Starlink.Com.Sso=") else { throw CloudError.refused("Sign-in hasn't finished yet.") }
        forget()
        guard Keychain.write(cookie) else { throw CloudError.refused("StarDash couldn't save the session to your keychain.") }
        do {
            return try await profile()
        } catch CloudError.signedOut {
            if Keychain.read() == cookie { Keychain.delete() }
            throw CloudError.signedOut
        }
    }

    /// Drops everything learned from the session. The keychain item is the caller's to delete.
    func forget() {
        generation += 1
        token = nil
        refreshing = nil
        ids = nil
        controller = nil
    }

    private func freshCookie(force: Bool) async throws -> String {
        guard let base = Keychain.read() else { throw CloudError.signedOut }
        if !force, let token, Date().timeIntervalSince(token.at) < Self.tokenLife { return token.cookie }
        if !force, let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh(base) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Asks Starlink for a new short-lived token and folds the cookies it sets into the session.
    private func refresh(_ base: String) async throws -> String {
        let started = generation
        var request = URLRequest(url: Self.authURL)
        request.setValue(base, forHTTPHeaderField: "Cookie")
        let (_, response) = try await session.data(for: request)
        guard started == generation else { throw CloudError.signedOut }
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformed("a reply") }
        if http.statusCode == 401 || http.statusCode == 403 {
            token = nil
            ids = nil
            controller = nil
            throw CloudError.signedOut
        }
        let merged = Self.merge(base, http)
        // Saved so the next launch starts from what Starlink last issued.
        if merged != base, Keychain.read() == base { Keychain.write(merged) }
        token = (merged, Date())
        return merged
    }

    /// Applies Set-Cookie lines to a Cookie header the way a browser would. Starlink splits a large
    /// token into numbered pieces and resends all of them, so every name is replaced, not just the first.
    static func merge(_ header: String, _ response: HTTPURLResponse) -> String {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url ?? authURL)
        guard !cookies.isEmpty else { return header }
        var jar: [(String, String)] = header.split(separator: ";").compactMap { part in
            guard let eq = part.firstIndex(of: "=") else { return nil }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        let now = Date()
        for cookie in cookies {
            jar.removeAll { $0.0 == cookie.name }
            if let expires = cookie.expiresDate, expires <= now { continue }
            jar.append((cookie.name, cookie.value))
        }
        return jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// Runs with a valid token. A token that lapses mid-flight gets one forced refresh and one more try.
    private func withSession<T>(_ run: (String) async throws -> T) async throws -> T {
        do {
            return try await run(try await freshCookie(force: false))
        } catch CloudError.signedOut {
            guard Keychain.read() != nil else { throw CloudError.signedOut }
            try await Task.sleep(for: .milliseconds(150))
            return try await run(try await freshCookie(force: true))
        }
    }

    // MARK: JSON calls

    private func json(_ url: URL, cookie: String, post body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformed("a reply") }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudError.signedOut }
        guard (200..<300).contains(http.statusCode) else { throw CloudError.http(http.statusCode) }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CloudError.malformed("a reply")
        }
    }

    private func api(_ path: String, cookie: String, post body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: Self.api + path) else { throw CloudError.refused("Bad address.") }
        return try await json(url, cookie: cookie, post: body)
    }

    /// The account number and first service line everything else hangs off.
    private func accountIDs(_ cookie: String) async throws -> (account: String, serviceLine: String) {
        if let ids, Date().timeIntervalSince(ids.at) < Self.idsLife { return (ids.account, ids.serviceLine) }
        let list = try await api("/webagg/v2/accounts/service-lines?limit=100&page=0&isConverting=false&serviceAddressId=&onlyActive=false&searchString=&onlyNoUts=false",
                                 cookie: cookie)
        let first = ((list as? [String: Any])?["content"] as? [String: Any])?["results"] as? [[String: Any]]
        guard let line = first?.first, let sl = line["serviceLineNumber"] as? String,
              let acc = line["accountReferenceId"] as? String else {
            throw CloudError.refused("This Starlink account has no service line.")
        }
        ids = (acc, sl, Date())
        return (acc, sl)
    }

    func profile() async throws -> CloudProfile {
        try await withSession { cookie in
            let (acc, sl) = try await accountIDs(cookie)
            var profile = CloudProfile(accountNumber: acc, serviceLine: sl)
            // The name is a nice extra. A miss here shouldn't fail the whole account.
            if let identity = try? await json(Self.authURL, cookie: cookie) as? [String: Any] {
                profile.name = (identity["name"] as? String) ?? (identity["givenName"] as? String)
                profile.email = identity["email"] as? String
            }
            return profile
        }
    }

    func billing() async throws -> BillingUsage {
        try await withSession { cookie in
            let (acc, sl) = try await accountIDs(cookie)
            let reply = try await api("/telemetryagg/v1/data-usage/account/\(acc)/service-line/\(sl)/annotated", cookie: cookie)
            guard let content = (reply as? [String: Any])?["content"] as? [String: Any] else {
                throw CloudError.malformed("usage")
            }
            let cycles = (content["billingCyclesAnnotated"] as? [[String: Any]] ?? []).enumerated().compactMap { index, raw -> BillingCycle? in
                guard let start = Self.date(raw["startDate"]), let end = Self.date(raw["endDate"]) else { return nil }
                let daily = (raw["dailyData"] as? [Any] ?? []).map { day -> Double in
                    Self.number((day as? [Any])?.first ?? day) ?? 0
                }
                return BillingCycle(id: index, start: start, end: end, totalGB: Self.number(raw["totalAmountGB"]) ?? daily.reduce(0, +), daily: daily)
            }
            let plan = content["servicePlan"] as? [String: Any]
            let bucket = (content["dataBuckets"] as? [[String: Any]])?.first?["name"] as? String
            return BillingUsage(cycles: cycles, limitGB: Self.number(plan?["usageLimitGB"]), bucketName: bucket)
        }
    }

    /// The router to send changes to, named by the account. A mesh node reports as a router too,
    /// and only the controller sits zero hops from itself. Writes never reuse a cached answer.
    private func controllerID(_ cookie: String, cached: Bool) async throws -> String {
        if cached, let controller, Date().timeIntervalSince(controller.at) < Self.idsLife { return controller.id }
        let (acc, _) = try await accountIDs(cookie)
        let reply = try await api("/device-data/cache/v1/telemetry", cookie: cookie, post: ["accountNumber": acc])
        let data = (reply as? [String: Any])?["data"] as? [String: Any]
        let legend = (data?["columnNamesByDeviceType"] as? [String: Any])?["r"] as? [String] ?? []
        let rows = data?["values"] as? [[Any]] ?? []
        guard let idColumn = legend.firstIndex(of: "DeviceId") else { throw CloudError.noRouter }
        let hopsColumn = legend.firstIndex(of: "WifiHopsFromController")
        var routers: [(id: String, hops: Double?)] = []
        for row in rows where (row.first as? String) == "r" && idColumn < row.count {
            guard let id = row[idColumn] as? String, id.hasPrefix("Router-") else { continue }
            let hops = hopsColumn.flatMap { $0 < row.count ? Self.number(row[$0]) : nil }
            routers.append((id, hops))
        }
        // A lone router is the controller when someone is about to write. A background read could
        // catch a mesh node alone during a bypass switch, so it doesn't get that benefit of the doubt.
        guard let chosen = routers.first(where: { $0.hops == 0 }) ?? (!cached && routers.count == 1 ? routers[0] : nil) else {
            throw CloudError.noRouter
        }
        controller = (chosen.id, Date())
        return chosen.id
    }

    // MARK: Device gateway

    /// One gRPC-web call to a device through Starlink. Returns the encoded Response.
    private func gateway(_ message: [UInt8], cookie: String, timeout: TimeInterval = 15) async throws -> [UInt8] {
        var request = URLRequest(url: Self.handleURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let length = UInt32(message.count)
        request.httpBody = Data([0, UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)] + message)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformed("a reply") }
        func fail(_ code: Int, _ text: String) -> Error {
            code == 16 ? CloudError.signedOut : CloudError.device(code, text.removingPercentEncoding ?? text)
        }
        if let status = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init), status != 0 {
            throw fail(status, http.value(forHTTPHeaderField: "grpc-message") ?? "")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudError.signedOut }
        guard http.statusCode == 200 else { throw CloudError.device(2, "HTTP \(http.statusCode)") }

        let body = [UInt8](data)
        var payload: [UInt8]?
        var i = 0
        while i + 5 <= body.count {
            let flag = body[i]
            let len = Int(body[i + 1]) << 24 | Int(body[i + 2]) << 16 | Int(body[i + 3]) << 8 | Int(body[i + 4])
            let start = i + 5
            guard start + len <= body.count else { break }
            let chunk = Array(body[start..<(start + len)])
            if flag & 0x80 != 0 {
                var status = 0
                var text = ""
                for line in String(decoding: chunk, as: UTF8.self).components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("grpc-status:") { status = Int(line.dropFirst(12).trimmingCharacters(in: .whitespaces)) ?? 0 }
                    if lower.hasPrefix("grpc-message:") { text = line.dropFirst(13).trimmingCharacters(in: .whitespaces) }
                }
                if status != 0 { throw fail(status, text) }
            } else {
                payload = chunk
            }
            i = start + len
        }
        guard let payload else { throw CloudError.malformed("an empty reply") }
        return payload
    }

    /// `Request { target_id = 13; <field> = body }`.
    private static func request(_ target: String, _ field: Int, _ body: [UInt8] = []) -> [UInt8] {
        ProtoWriter.field(13, body: Array(target.utf8)) + ProtoWriter.field(field, body: body)
    }

    /// `wifi_set_config { wifi_config { ... } }`.
    private static func setConfig(_ target: String, _ wifiConfig: RawProto) -> [UInt8] {
        request(target, 3001, ProtoWriter.field(1, body: wifiConfig.encoded()))
    }

    private func wifiConfig(_ target: String, _ cookie: String) async throws -> RawProto {
        let reply = try RawProto(try await gateway(Self.request(target, 3009), cookie: cookie))
        guard let config = try reply.message(3009)?.message(1), !config.fields.isEmpty else {
            throw CloudError.malformed("router settings")
        }
        return config
    }

    private func liveClients(_ target: String, _ cookie: String) async throws -> [WifiClient] {
        let reply = ProtoMessage(bytes: ArraySlice(try await gateway(Self.request(target, 3002), cookie: cookie)))
        return reply.message(3002)?.messages(1).map(WifiClient.init) ?? []
    }

    private func onRouter<T>(cachedTarget: Bool, _ run: (String, String) async throws -> T) async throws -> T {
        try await withSession { cookie in
            try await run(try await controllerID(cookie, cached: cachedTarget), cookie)
        }
    }

    /// Runs writes one at a time, each built from a fresh read.
    private func serialized(_ work: @escaping () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try await work()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }

    // MARK: Reads

    func routerSettings() async throws -> RouterCloudSettings {
        try await onRouter(cachedTarget: true) { target, cookie in
            let config = try await wifiConfig(target, cookie)
            var byName: [(ssid: String, bands: [String], guest: Bool, secured: Bool)] = []
            for network in try config.messages(1100) {
                let guest = (network.uint(1009) ?? 0) != 0
                for set in try network.messages(1007) {
                    guard let ssid = set.string(1005), !ssid.isEmpty else { continue }
                    let band = Self.bandName(set.uint(1011) ?? 0)
                    let secured = [2002, 2003, 2004].contains { set.has($0) }
                    if let i = byName.firstIndex(where: { $0.ssid == ssid }) {
                        if !band.isEmpty, !byName[i].bands.contains(band) { byName[i].bands.append(band) }
                        byName[i].secured = byName[i].secured || secured
                    } else {
                        byName.append((ssid, band.isEmpty ? [] : [band], guest, secured))
                    }
                }
            }
            let mesh = try config.messages(33).compactMap { entry -> RouterCloudSettings.MeshNode? in
                guard let id = entry.string(1), let node = try entry.message(2) else { return nil }
                let auth = node.uint(3) ?? 0
                return RouterCloudSettings.MeshNode(
                    id: id, name: node.string(1) ?? "Mesh node", trusted: auth == 2,
                    auth: ["Unknown", "New", "Trusted", "Not trusted"][Int(min(auth, 3))], hardware: node.string(9))
            }
            return RouterCloudSettings(
                networks: byName.map { .init(ssid: $0.ssid, bands: $0.bands, guest: $0.guest, secured: $0.secured) },
                nameservers: config.strings(30),
                customDNSAllowed: (config.uint(1117) ?? 0) == 0,
                mesh: mesh)
        }
    }

    // MARK: Writes

    /// Sets the router's DNS servers. An empty list goes back to Starlink's own.
    /// The router merges by apply flag, so this touches nothing else.
    func setNameservers(_ servers: [String]) async throws {
        guard let list = DNSList.normalized(servers) else { throw CloudError.refused("Those aren't valid DNS server addresses.") }
        var config = RawProto()
        for server in list { config.append(30, .bytes(Array(server.utf8))) }
        config.setBool(1054, true)
        try await serialized {
            try await self.retryingUnreachable {
                try await self.onRouter(cachedTarget: false) { target, cookie in
                    _ = try await self.gateway(Self.setConfig(target, config), cookie: cookie)
                }
            }
        }
    }

    /// Renames Wi-Fi networks and sets the passphrase. The router reports its passphrase masked and
    /// would store the mask if it came back, so every passphrase block gets the real one.
    /// `renames` maps a current name to a new one.
    func setWifi(renames: [String: String], password: String) async throws {
        if let problem = WifiRules.passwordProblem(password) { throw CloudError.refused(problem) }
        for name in renames.values {
            if let problem = WifiRules.nameProblem(name) { throw CloudError.refused(problem) }
        }
        try await serialized {
            try await self.onRouter(cachedTarget: false) { target, cookie in
                let config = try await self.wifiConfig(target, cookie)
                let networks = try config.messages(1100)
                guard !networks.isEmpty else {
                    throw CloudError.refused("The router didn't report its Wi-Fi networks, so nothing was sent.")
                }
                var secured = 0
                let rebuilt = try networks.map { network -> RawProto in
                    var network = network
                    // A guest network keeps its own password, or the people it was shared with get the main one.
                    let guest = (network.uint(1009) ?? 0) != 0
                    let sets = try network.messages(1007).map { set -> RawProto in
                        var set = set
                        // Router-assigned. Sending them back makes the router drop the whole change.
                        set.removeAll(1003)
                        set.removeAll(1017)
                        if let old = set.string(1005), let new = renames[old] { set.setString(1005, new) }
                        // WPA2, WPA3 and mixed. RADIUS also has a password, but it's a server login.
                        for key in [2002, 2003, 2004] where set.has(key) && !guest {
                            var auth = try set.message(key) ?? RawProto()
                            auth.setString(1, password)
                            set.setMessages(key, [auth])
                            secured += 1
                        }
                        return set
                    }
                    network.setMessages(1007, sets)
                    return network
                }
                guard secured > 0 else {
                    throw CloudError.refused("This router's Wi-Fi has no password to change, so nothing was sent.")
                }
                var change = RawProto()
                change.setMessages(1100, rebuilt)
                change.setBool(1101, true)
                // Read the change back before sending, so a mangled copy never reaches the router.
                let check = try RawProto(change.encoded())
                guard try check.messages(1100).count == networks.count else {
                    throw CloudError.malformed("router settings")
                }
                _ = try await self.gateway(Self.setConfig(target, change), cookie: cookie)
            }
        }
    }

    /// Pauses or resumes one device. A pause is a block schedule named `_permanent` covering the whole
    /// week. The router only takes its whole client list, so every other entry and schedule is kept.
    /// `protect` holds this Mac's addresses: pausing it would leave nothing here able to undo it.
    func setPaused(clientID: UInt64, paused: Bool, protect: Set<String>) async throws {
        try await serialized {
            try await self.onRouter(cachedTarget: true) { target, cookie in
                let config = try await self.wifiConfig(target, cookie)
                var clients = try config.messages(74)
                let before = clients.count
                let live = try await self.liveClients(target, cookie).first { $0.clientID == clientID }
                var index = clients.firstIndex { $0.uint(1) == clientID }
                if paused {
                    guard let live else { throw CloudError.refused("That device isn't connected right now, so it can't be paused.") }
                    if let ip = live.ip, protect.contains(ip) {
                        throw CloudError.refused("StarDash won't pause the Mac it runs on. Nothing here could resume it.")
                    }
                }
                if index == nil {
                    // No saved entry means no pause schedule to remove.
                    if !paused { return }
                    guard let mac = live?.mac else { throw CloudError.refused("The router doesn't know this device right now.") }
                    var entry = RawProto()
                    entry.append(1, .varint(clientID))
                    entry.setString(2, mac)
                    clients.append(entry)
                    index = clients.count - 1
                }
                guard let i = index else { return }
                var entry = clients[i]
                var schedules = try entry.messages(5).filter { $0.string(2) != Self.permanentGroup }
                if paused {
                    var range = RawProto()
                    range.append(1, .varint(0))
                    range.append(2, .varint(Self.weekMinutes))
                    var schedule = RawProto()
                    schedule.setMessages(1, [range])
                    schedule.setString(2, Self.permanentGroup)
                    schedules.append(schedule)
                }
                entry.setMessages(5, schedules)
                clients[i] = entry

                var change = RawProto()
                change.setMessages(74, clients)
                change.setBool(1089, true)
                let check = try RawProto(change.encoded())
                guard try check.messages(74).count == clients.count, clients.count >= before else {
                    throw CloudError.malformed("the device list")
                }
                _ = try await self.gateway(Self.setConfig(target, change), cookie: cookie)
            }
        }
    }

    /// Wipes the router back to how it shipped. The reset takes the network down, which can cut
    /// the reply off, so a dropped connection after sending counts as sent.
    func factoryResetRouter() async throws {
        try await serialized {
            try await self.retryingUnreachable {
                try await self.onRouter(cachedTarget: false) { target, cookie in
                    do {
                        _ = try await self.gateway(Self.request(target, 1011), cookie: cookie)
                    } catch let error as URLError where error.code != .notConnectedToInternet && error.code != .cannotFindHost {
                        return
                    }
                }
            }
        }
    }

    /// The gateway sometimes has no link to the router for a moment. For a change that names one
    /// field, the same request can go again after a pause, built from scratch.
    private func retryingUnreachable(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch CloudError.device(5, _) {
            controller = nil
            try await Task.sleep(for: .seconds(5))
            try await work()
        }
    }

    // MARK: Helpers

    private static func bandName(_ band: UInt64) -> String {
        switch band {
        case 2: return "2.4 GHz"
        case 5: return "5 GHz"
        case 6: return "5 GHz high"
        default: return ""
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: text) { return d }
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: text) { return d }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            plain.dateFormat = format
            if let d = plain.date(from: text) { return d }
        }
        return nil
    }
}

// MARK: Validation

enum WifiRules {
    /// WPA2's own bounds. A passphrase outside them is one no device could use to rejoin.
    static func passwordProblem(_ password: String) -> String? {
        if password.count < 8 { return "The password needs at least 8 characters." }
        if password.count > 63 { return "The password can't be longer than 63 characters." }
        if password.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) {
            return "Use letters, numbers, spaces and standard symbols only. Some devices can't type anything else."
        }
        return nil
    }

    static func nameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The network name can't be empty." }
        if name.utf8.count > 32 { return "The network name can't be longer than 32 bytes." }
        return nil
    }
}

enum DNSList {
    /// The most the Starlink app offers: one main server and three backups.
    static let maxServers = 4

    /// The addresses as they'll be sent, or nil when any isn't a literal IP address.
    static func normalized(_ servers: [String]) -> [String]? {
        guard servers.count <= maxServers else { return nil }
        var out: [String] = []
        for raw in servers {
            guard let address = address(raw) else { return nil }
            if !out.contains(address) { out.append(address) }
        }
        return out
    }

    static func address(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if isIPv4(text) { return text }
        guard !text.contains("."), !text.contains("%") else { return nil }
        var storage = in6_addr()
        return inet_pton(AF_INET6, text, &storage) == 1 ? text.lowercased() : nil
    }

    /// Four parts from 0 to 255, no leading zeros, which some resolvers read as octal.
    private static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255 else { return false }
            return part == "0" || !part.hasPrefix("0")
        }
    }
}

// MARK: Protobuf that survives a round trip

/// A protobuf message kept field by field, so it can be edited and sent back with nothing lost.
/// Unlike `ProtoMessage` it refuses anything malformed instead of stopping quietly, because a
/// truncated copy written back to the router would wipe the settings it left out.
struct RawProto {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    var fields: [(number: Int, value: Value)] = []

    init() {}

    init(_ b: [UInt8]) throws {
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw CloudError.malformed("router settings")
        }
        while i < b.count {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0 else { throw CloudError.malformed("router settings") }
            switch key & 7 {
            case 0:
                fields.append((number, .varint(try varint())))
            case 1:
                guard i + 8 <= b.count else { throw CloudError.malformed("router settings") }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                i += 8
                fields.append((number, .fixed64(v)))
            case 2:
                let len = try varint()
                guard len <= UInt64(b.count - i) else { throw CloudError.malformed("router settings") }
                fields.append((number, .bytes(Array(b[i..<(i + Int(len))]))))
                i += Int(len)
            case 5:
                guard i + 4 <= b.count else { throw CloudError.malformed("router settings") }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(b[i + k]) << UInt32(8 * k) }
                i += 4
                fields.append((number, .fixed32(v)))
            default:
                throw CloudError.malformed("router settings")
            }
        }
    }

    func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for (number, value) in fields {
            let tag = UInt64(number) << 3
            switch value {
            case .varint(let x):
                out += ProtoWriter.varint(tag) + ProtoWriter.varint(x)
            case .fixed64(let x):
                out += ProtoWriter.varint(tag | 1) + (0..<8).map { UInt8(x >> (8 * UInt64($0)) & 0xff) }
            case .bytes(let x):
                out += ProtoWriter.field(number, body: x)
            case .fixed32(let x):
                out += ProtoWriter.varint(tag | 5) + (0..<4).map { UInt8(x >> (8 * UInt32($0)) & 0xff) }
            }
        }
        return out
    }

    func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }

    func uint(_ number: Int) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let x) = field.value { return x }
        }
        return nil
    }

    func string(_ number: Int) -> String? {
        for field in fields.reversed() where field.number == number {
            if case .bytes(let x) = field.value { return String(decoding: x, as: UTF8.self) }
        }
        return nil
    }

    func strings(_ number: Int) -> [String] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let x) = field.value else { return nil }
            return String(decoding: x, as: UTF8.self)
        }
    }

    func message(_ number: Int) throws -> RawProto? {
        for field in fields.reversed() where field.number == number {
            if case .bytes(let x) = field.value { return try RawProto(x) }
        }
        return nil
    }

    func messages(_ number: Int) throws -> [RawProto] {
        try fields.compactMap { field in
            guard field.number == number, case .bytes(let x) = field.value else { return nil }
            return try RawProto(x)
        }
    }

    mutating func removeAll(_ number: Int) { fields.removeAll { $0.number == number } }

    mutating func append(_ number: Int, _ value: Value) { fields.append((number, value)) }

    mutating func setString(_ number: Int, _ text: String) {
        replace(number, with: [.bytes(Array(text.utf8))])
    }

    mutating func setBool(_ number: Int, _ on: Bool) {
        replace(number, with: [.varint(on ? 1 : 0)])
    }

    mutating func setMessages(_ number: Int, _ messages: [RawProto]) {
        replace(number, with: messages.map { .bytes($0.encoded()) })
    }

    /// Swaps every copy of a field for new values, where the first copy was.
    private mutating func replace(_ number: Int, with values: [Value]) {
        let at = fields.firstIndex { $0.number == number } ?? fields.count
        removeAll(number)
        let position = min(at, fields.count)
        fields.insert(contentsOf: values.map { (number, $0) }, at: position)
    }
}
