import Darwin
import Foundation

/// ICMP echo over a datagram socket, which macOS allows without root.
/// HTTP requests can't show packet loss because TCP quietly resends; real pings can.
enum Pinger {
    struct Result {
        var sent: Int
        /// Round-trip times in milliseconds, in the order the replies were sent.
        var times: [Double]

        var received: Int { times.count }
        var loss: Double { sent > 0 ? 1 - Double(received) / Double(sent) : 0 }

        var median: Double? {
            guard !times.isEmpty else { return nil }
            return times.sorted()[times.count / 2]
        }

        /// Mean change between one ping and the next.
        var jitter: Double? {
            guard times.count > 1 else { return nil }
            let steps = zip(times, times.dropFirst()).map { abs($0 - $1) }
            return steps.reduce(0, +) / Double(steps.count)
        }
    }

    /// Sends `count` pings `interval` seconds apart, then waits `timeout` for late replies.
    /// Blocks for the whole run, so call it off the main thread. Returns nil if the socket can't be opened.
    static func run(host: String = "1.1.1.1", count: Int = 50, interval: Double = 0.05, timeout: Double = 0.8) -> Result? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let id = UInt16.random(in: 1...UInt16.max)
        var sentAt = [Double](repeating: 0, count: count)
        var rtt = [Double?](repeating: nil, count: count)
        var sent = 0
        let start = now()

        func receive(until deadline: Double) {
            var buffer = [UInt8](repeating: 0, count: 1500)
            while true {
                let wait = deadline - now()
                guard wait > 0 else { return }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, Int32(max(1, wait * 1000))) > 0 else { continue }
                let n = recv(fd, &buffer, buffer.count, 0)
                let arrived = now()
                guard n >= 8 else { continue }
                // macOS hands back the IP header in front of the ICMP reply.
                let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
                guard n >= offset + 8, buffer[offset] == 0 else { continue }
                let replyID = UInt16(buffer[offset + 4]) << 8 | UInt16(buffer[offset + 5])
                let seq = Int(UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7]))
                guard replyID == id, seq < sent, rtt[seq] == nil else { continue }
                rtt[seq] = (arrived - sentAt[seq]) * 1000
            }
        }

        for seq in 0..<count {
            var packet = [UInt8](repeating: 0, count: 56)
            packet[0] = 8
            packet[4] = UInt8(id >> 8)
            packet[5] = UInt8(id & 0xFF)
            packet[6] = UInt8(seq >> 8)
            packet[7] = UInt8(seq & 0xFF)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)

            sentAt[seq] = now()
            let ok = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok > 0 { sent += 1 } else if sent == 0 { return nil } else { break }
            receive(until: start + Double(seq + 1) * interval)
        }
        receive(until: now() + timeout)
        return Result(sent: sent, times: rtt.prefix(sent).compactMap { $0 })
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
        }
        if bytes.count % 2 == 1 { sum += UInt32(bytes[bytes.count - 1]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
