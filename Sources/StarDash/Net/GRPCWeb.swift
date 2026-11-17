import Foundation
import Network

enum TelemetryError: LocalizedError {
    case unreachable(String)
    case timeout
    case http(Int)
    case grpc(Int, String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): return "Unreachable (\(why))"
        case .timeout: return "Timed out"
        case .http(let code): return "HTTP \(code)"
        case .grpc(let code, let msg): return msg.isEmpty ? "gRPC status \(code)" : msg
        case .malformed: return "Malformed response"
        }
    }
}

/// Unary gRPC-web over a raw TCP connection.
///
/// URLSession can't pin a request to an interface, and a VPN that claims
/// 192.168.100.1 swallows dish traffic. NWConnection lets us refuse tunnel
/// interfaces so the request leaves over Wi-Fi or Ethernet.
struct GRPCWebClient {
    let host: String
    let port: UInt16
    var avoidTunnels = true

    private static let queue = DispatchQueue(label: "stardash.grpc", qos: .utility)

    /// Sends `Request { <field>: body }` and returns the decoded `Response`.
    func call(_ field: Int, body: [UInt8] = [], timeout: TimeInterval = 4) async throws -> ProtoMessage {
        let message = ProtoWriter.field(field, body: body)
        let len = UInt32(message.count)
        let frame: [UInt8] = [0, UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff)] + message

        let head = "POST /SpaceX.API.Device.Device/Handle HTTP/1.1\r\n"
            + "Host: \(host):\(port)\r\n"
            + "Content-Type: application/grpc-web+proto\r\n"
            + "X-Grpc-Web: 1\r\n"
            + "Accept: */*\r\n"
            + "Content-Length: \(frame.count)\r\n"
            + "Connection: close\r\n\r\n"
        let request = Data(head.utf8) + Data(frame)

        guard avoidTunnels else {
            return try Self.parse(try await exchange(request, timeout: timeout, interface: nil))
        }

        // Pin to a physical interface. The one that worked last time goes first.
        let candidates = await PhysicalInterfaces.shared.candidates(for: host)
        guard !candidates.isEmpty else {
            return try Self.parse(try await exchange(request, timeout: timeout, interface: nil))
        }
        var lastError: Error = TelemetryError.timeout
        for (index, interface) in candidates.enumerated() {
            do {
                let raw = try await exchange(request, timeout: index == 0 ? timeout : min(timeout, 2), interface: interface)
                PhysicalInterfaces.shared.remember(interface, for: host)
                return try Self.parse(raw)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func exchange(_ request: Data, timeout: TimeInterval, interface: NWInterface?) async throws -> [UInt8] {
        let params = NWParameters.tcp
        if let interface { params.requiredInterface = interface }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw TelemetryError.malformed }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let q = Self.queue

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
                var done = false
                var buffer: [UInt8] = []

                func finish(_ result: Result<[UInt8], Error>) {
                    guard !done else { return }
                    done = true
                    conn.cancel()
                    cont.resume(with: result)
                }

                func receive() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                        if let data { buffer.append(contentsOf: data) }
                        if isComplete || error != nil || Self.isComplete(buffer) {
                            if buffer.isEmpty, let error {
                                finish(.failure(TelemetryError.unreachable(error.localizedDescription)))
                            } else {
                                finish(.success(buffer))
                            }
                        } else {
                            receive()
                        }
                    }
                }

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: request, completion: .contentProcessed { error in
                            if let error { finish(.failure(TelemetryError.unreachable(error.localizedDescription))) }
                        })
                        receive()
                    case .failed(let error):
                        finish(.failure(TelemetryError.unreachable(error.localizedDescription)))
                    case .waiting(let error):
                        // No route right now. Fail fast; the poller retries.
                        finish(.failure(TelemetryError.unreachable(error.localizedDescription)))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                q.asyncAfter(deadline: .now() + timeout) { finish(.failure(TelemetryError.timeout)) }
                conn.start(queue: q)
            }
        } onCancel: {
            conn.cancel()
        }
    }

    // MARK: HTTP + gRPC-web framing

    private static func headerEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i
        }
        return nil
    }

    private static func headers(_ b: [UInt8], end: Int) -> (status: Int, fields: [String: String]) {
        let text = String(decoding: b[0..<end], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var fields: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, fields)
    }

    /// Returns the de-chunked body, and whether the terminal chunk was seen.
    private static func dechunk(_ b: ArraySlice<UInt8>) -> (body: [UInt8], finished: Bool) {
        var out: [UInt8] = []
        var i = b.startIndex
        while i < b.endIndex {
            var j = i
            while j + 1 < b.endIndex, !(b[j] == 13 && b[j + 1] == 10) { j += 1 }
            guard j + 1 < b.endIndex else { return (out, false) }
            let sizeText = String(decoding: b[i..<j], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return (out, false) }
            if size == 0 { return (out, true) }
            let start = j + 2
            guard start + size <= b.endIndex else { return (out, false) }
            out.append(contentsOf: b[start..<(start + size)])
            i = start + size + 2
        }
        return (out, false)
    }

    private static func isComplete(_ b: [UInt8]) -> Bool {
        guard let end = headerEnd(b) else { return false }
        let h = headers(b, end: end)
        let body = b[(end + 4)...]
        if h.fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return dechunk(body).finished
        }
        if let length = h.fields["content-length"].flatMap(Int.init) {
            return body.count >= length
        }
        return false
    }

    private static func parse(_ b: [UInt8]) throws -> ProtoMessage {
        guard let end = headerEnd(b) else { throw TelemetryError.malformed }
        let h = headers(b, end: end)
        guard h.status == 200 else { throw TelemetryError.http(h.status) }

        var grpcStatus = h.fields["grpc-status"].flatMap(Int.init)
        var grpcMessage = h.fields["grpc-message"] ?? ""

        let raw = b[(end + 4)...]
        let body: [UInt8] = h.fields["transfer-encoding"]?.lowercased().contains("chunked") == true
            ? dechunk(raw).body
            : Array(raw)

        var payload: [UInt8] = []
        var i = 0
        while i + 5 <= body.count {
            let flag = body[i]
            let len = Int(body[i + 1]) << 24 | Int(body[i + 2]) << 16 | Int(body[i + 3]) << 8 | Int(body[i + 4])
            let start = i + 5
            guard start + len <= body.count else { break }
            let chunk = body[start..<(start + len)]
            if flag & 0x80 != 0 {
                for line in String(decoding: chunk, as: UTF8.self).components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("grpc-status:") {
                        grpcStatus = Int(line.dropFirst(12).trimmingCharacters(in: .whitespaces))
                    } else if lower.hasPrefix("grpc-message:") {
                        grpcMessage = line.dropFirst(13).trimmingCharacters(in: .whitespaces)
                    }
                }
            } else {
                payload.append(contentsOf: chunk)
            }
            i = start + len
        }

        if let status = grpcStatus, status != 0 {
            throw TelemetryError.grpc(status, grpcMessage.removingPercentEncoding ?? grpcMessage)
        }
        guard !payload.isEmpty else { throw TelemetryError.malformed }
        return ProtoMessage(bytes: ArraySlice(payload))
    }
}

/// Tracks Wi-Fi and Ethernet interfaces so requests can be pinned to one of them.
final class PhysicalInterfaces: @unchecked Sendable {
    static let shared = PhysicalInterfaces()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var interfaces: [NWInterface] = []
    private var preferred: [String: String] = [:]
    private var ready = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let physical = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
            self.lock.lock()
            self.interfaces = physical
            self.ready = true
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "stardash.path", qos: .utility))
    }

    func candidates(for host: String) async -> [NWInterface] {
        // The monitor reports asynchronously, so give the first update a moment at launch.
        for _ in 0..<20 where !isReady() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return sorted(for: host)
    }

    private func isReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    private func sorted(for host: String) -> [NWInterface] {
        lock.lock()
        defer { lock.unlock() }
        let favorite = preferred[host]
        return interfaces.sorted { a, _ in a.name == favorite }
    }

    func remember(_ interface: NWInterface, for host: String) {
        lock.lock()
        preferred[host] = interface.name
        lock.unlock()
    }
}
