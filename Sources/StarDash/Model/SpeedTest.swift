import Foundation
import Observation

private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: Int64 = 0
    private var _sent: Int64 = 0
    private var _refusedFor: Double?

    /// Set when the server answered 429: how long it asked us to wait, in seconds (0 if it didn't say).
    var refusedFor: Double? { lock.lock(); defer { lock.unlock() }; return _refusedFor }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            lock.lock(); _refusedFor = wait; lock.unlock()
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    var received: Int64 { lock.lock(); defer { lock.unlock() }; return _received }
    var sent: Int64 { lock.lock(); defer { lock.unlock() }; return _sent }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); _received += Int64(data.count); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); _sent += bytesSent; lock.unlock()
    }
}

struct SpeedResult: Codable, Identifiable {
    var id: Double { date.timeIntervalSince1970 }
    var date: Date
    var macDown: Double?
    var macUp: Double?
    var routerDown: Double?
    var routerUp: Double?
    var latency: Double?
    var jitter: Double?
    /// Share of pings from this Mac that got no reply, 0 to 1.
    var loss: Double?
    var dishPeakDown: Double?
    var dishPeakUp: Double?

    /// The headline number: what this Mac got, or the router's figure when the Mac test failed.
    var bestDown: Double? { macDown ?? routerDown }
    var bestUp: Double? { macUp ?? routerUp }
}

/// Two tests side by side: the router's own test (router to internet) and one from this Mac
/// (Mac to Cloudflare). The gap between them is your Wi-Fi.
@MainActor
@Observable
final class SpeedTest {
    enum Stage: Equatable {
        case idle, latency, routerDown, routerUp, macDown, macUp

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .latency: return "Measuring latency"
            case .routerDown: return "Router download"
            case .routerUp: return "Router upload"
            case .macDown: return "This Mac download"
            case .macUp: return "This Mac upload"
            }
        }

        var isUpload: Bool { self == .routerUp || self == .macUp }
    }

    var stage: Stage = .idle
    var error: String?
    /// Something worth telling the user about a run that otherwise finished, such as one part being refused.
    var notice: String?
    var liveMbps: Double = 0
    /// Samples of the current stage, for the live trace under the gauge.
    var liveSeries: [Double] = []
    /// 0 to 1 across the whole run.
    var progress: Double = 0

    var current = SpeedResult(date: Date())
    var history: [SpeedResult] = []
    var includeRouter = UserDefaults.standard.object(forKey: "speedIncludeRouter") as? Bool ?? false {
        didSet { UserDefaults.standard.set(includeRouter, forKey: "speedIncludeRouter") }
    }

    /// Off only when the user asks for the router test alone.
    var includeMac = UserDefaults.standard.object(forKey: "speedIncludeMac") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeMac, forKey: "speedIncludeMac") }
    }
    /// Share of the progress bar the router test takes: all of it when it runs alone.
    private var routerSpan = 0.45

    var isRunning: Bool { stage != .idle }
    var last: SpeedResult? { history.first }

    init() { load() }

    func run(store: TelemetryStore) async {
        guard !isRunning else { return }
        error = nil
        notice = nil
        current = SpeedResult(date: Date())
        progress = 0

        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                if let dish = store.dish, let self {
                    self.current.dishPeakDown = max(self.current.dishPeakDown ?? 0, dish.downBps)
                    self.current.dishPeakUp = max(self.current.dishPeakUp ?? 0, dish.upBps)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }

        var problems: [String] = []
        let useRouter = includeRouter && store.router != nil
        let useMac = includeMac || !useRouter
        routerSpan = useMac ? 0.45 : 1
        if useRouter, let problem = await runRouter(client: store.routerClient) { problems.append(problem) }
        if useMac, let problem = await runMac(startProgress: useRouter ? 0.45 : 0) { problems.append(problem) }

        begin(.idle)
        progress = 1
        current.date = Date()
        if current.bestDown != nil {
            history.insert(current, at: 0)
            history = Array(history.prefix(200))
            save()
        } else {
            error = problems.first ?? "Speed test failed"
        }
    }

    private func begin(_ next: Stage) {
        stage = next
        liveSeries = []
        liveMbps = 0
    }

    private func record(_ mbps: Double) {
        liveMbps = max(0, mbps)
        liveSeries.append(liveMbps)
    }

    // MARK: Router

    private func runRouter(client: GRPCWebClient) async -> String? {
        begin(.routerDown)
        let before = try? await client.call(1028)
        let previousID = before?.message(1028)?.message(1)?.uint(2)

        do {
            _ = try await client.call(1027, timeout: 8)
        } catch {
            return "Router test unavailable: \(error.localizedDescription)"
        }

        let started = Date()
        var sawRunning = false
        var seen = 0
        while Date().timeIntervalSince(started) < 60 {
            try? await Task.sleep(for: .seconds(1))
            guard let response = try? await client.call(1028),
                  let status = response.message(1028)?.message(1) else { continue }
            let running = status.bool(1)
            let down = (status.message(1001)?.floats(1) ?? []).map { Double($0) }
            let up = (status.message(1000)?.floats(1) ?? []).map { Double($0) }
            sawRunning = sawRunning || running || status.uint(2) != previousID

            if running {
                if !up.isEmpty, stage != .routerUp { begin(.routerUp); seen = 0 }
                let series = up.isEmpty ? down : up
                for value in series.dropFirst(seen) { record(value) }
                seen = series.count
            }
            if !down.isEmpty { current.routerDown = Self.settled(down) }
            if !up.isEmpty { current.routerUp = Self.settled(up) }
            progress = min(routerSpan, Date().timeIntervalSince(started) / 30 * routerSpan)
            if sawRunning, !running, Date().timeIntervalSince(started) > 2 {
                return current.routerDown == nil ? "Router test returned no result" : nil
            }
        }
        return current.routerDown == nil ? "Router test timed out" : nil
    }

    /// Mean of the upper half of the samples, which drops the ramp-up.
    private static func settled(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let top = sorted.suffix(max(1, sorted.count / 2))
        return top.reduce(0, +) / Double(top.count)
    }

    // MARK: This Mac

    private func runMac(startProgress: Double) async -> String? {
        let base = "https://speed.cloudflare.com"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let span = 1 - startProgress

        begin(.latency)
        // Real pings run alongside the HTTP round trips: they give packet loss, and a truer latency.
        let pinging = Task.detached(priority: .userInitiated) { Pinger.run() }
        let plain = URLSession(configuration: config)
        var pings: [Double] = []
        for _ in 0..<8 {
            guard let url = URL(string: "\(base)/__down?bytes=0") else { break }
            let t0 = Date()
            if (try? await plain.data(from: url)) != nil {
                pings.append(Date().timeIntervalSince(t0) * 1000)
            }
        }
        plain.invalidateAndCancel()
        let icmp = await pinging.value
        guard !pings.isEmpty else { return "Couldn't reach the speed test server" }
        // The first request pays for the TLS handshake, so it's left out.
        let warm = pings.count > 1 ? Array(pings.dropFirst()) : pings
        current.latency = warm.min()
        let mean = warm.reduce(0, +) / Double(warm.count)
        current.jitter = (warm.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(warm.count)).squareRoot()
        // No replies at all means pings are blocked somewhere, which says nothing about loss.
        if let icmp, icmp.received > 0 {
            current.loss = icmp.loss
            if icmp.received >= 5, let median = icmp.median {
                current.latency = median
                current.jitter = icmp.jitter
            }
        }
        progress = startProgress + span * 0.08

        begin(.macDown)
        let downCounter = ByteCounter()
        let downSession = URLSession(configuration: config, delegate: downCounter, delegateQueue: nil)
        // Cloudflare answers 403 above roughly 50 MB per request, so use more, smaller streams.
        if let url = URL(string: "\(base)/__down?bytes=50000000") {
            for _ in 0..<6 { downSession.dataTask(with: url).resume() }
        }
        current.macDown = await measure(seconds: 7, from: startProgress + span * 0.08, to: startProgress + span * 0.58,
                                        stop: { downCounter.refusedFor != nil }) { downCounter.received }
        downSession.invalidateAndCancel()

        // Cloudflare turns downloads away for up to an hour after a burst of tests. Rather than report
        // nothing, measure against public test files instead, mostly from the nearest region.
        if current.macDown == nil, downCounter.refusedFor != nil {
            begin(.macDown)
            let backupCounter = ByteCounter()
            let backup = URLSession(configuration: config, delegate: backupCounter, delegateQueue: nil)
            for host in ["sin", "sin", "sin", "sin", "fsn1", "ash"] {
                if let url = URL(string: "https://\(host)-speed.hetzner.com/1GB.bin") { backup.dataTask(with: url).resume() }
            }
            current.macDown = await measure(seconds: 7, from: startProgress + span * 0.08, to: startProgress + span * 0.58) { backupCounter.received }
            backup.invalidateAndCancel()
            notice = current.macDown == nil
                ? "The download test from this Mac couldn't run: the main test server is limiting this connection and the backup didn't answer."
                : "Download from this Mac was measured against a backup server, because the main one is limiting this connection after several runs. It can read a little lower than usual."
        }

        // Hold the download figure for a beat, then drop to zero, so the switch to upload is plain to see.
        if let down = current.macDown { liveMbps = down }
        try? await Task.sleep(for: .milliseconds(900))
        begin(.macUp)
        try? await Task.sleep(for: .milliseconds(450))
        let upCounter = ByteCounter()
        let upSession = URLSession(configuration: config, delegate: upCounter, delegateQueue: nil)
        if let url = URL(string: "\(base)/__up") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let payload = Data(count: 25_000_000)
            for _ in 0..<3 { upSession.uploadTask(with: request, from: payload).resume() }
        }
        current.macUp = await measure(seconds: 6, from: startProgress + span * 0.58, to: 1) { upCounter.sent }
        upSession.invalidateAndCancel()
        return nil
    }

    /// Samples a byte counter and returns Mbps, ignoring the first second of ramp-up.
    ///
    /// The live reading is a rate over a trailing 1.5 s window, then eased. Upload progress arrives in
    /// bursts (the system reports bytes as it hands whole buffers to the socket), so a per-tick rate
    /// swings between a spike and zero even on a steady link.
    private func measure(seconds: Double, from: Double, to: Double, stop: (() -> Bool)? = nil,
                         _ bytes: @escaping () -> Int64) async -> Double? {
        let start = Date()
        var samples: [(time: Date, count: Int64)] = [(start, 0)]
        var baseline: (Date, Int64)?
        var smoothed: Double?
        var result: Double?
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(100))
            if stop?() == true { return nil }
            let now = Date()
            let count = bytes()
            samples.append((now, count))
            while samples.count > 2, now.timeIntervalSince(samples[1].time) >= 1.5 { samples.removeFirst() }

            // The first moments are the socket buffer filling, not the link. Keep them out of the reading.
            while samples.count > 2, samples[0].time.timeIntervalSince(start) < 0.6 { samples.removeFirst() }

            let span = now.timeIntervalSince(samples[0].time)
            if span >= 0.3, samples[0].time.timeIntervalSince(start) >= 0.6 {
                let windowed = Double(count - samples[0].count) * 8 / span / 1e6
                // Eases up from zero, so every stage visibly starts from the bottom of the dial.
                let eased = (smoothed ?? 0) + (windowed - (smoothed ?? 0)) * 0.25
                smoothed = eased
                record(eased)
            }

            progress = from + (to - from) * min(1, now.timeIntervalSince(start) / seconds)
            if baseline == nil, now.timeIntervalSince(start) >= 1 { baseline = (now, count) }
            if let b = baseline, now.timeIntervalSince(b.0) > 0.5 {
                result = Double(count - b.1) * 8 / now.timeIntervalSince(b.0) / 1e6
            }
        }
        return (result ?? 0) > 0 ? result : nil
    }

    // MARK: History

    private var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("speedtests.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let stored = try? JSONDecoder().decode([SpeedResult].self, from: data) else { return }
        history = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    func clearHistory() {
        history = []
        save()
    }
}
