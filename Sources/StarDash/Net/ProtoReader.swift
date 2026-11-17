import Foundation

/// Schema-less protobuf wire reader. Starlink ships no stable public schema,
/// so fields are read by number and anything missing comes back nil.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    private var fields: [Int: [Value]] = [:]

    static let empty = ProtoMessage(bytes: [])

    init(_ data: Data) { self.init(bytes: ArraySlice([UInt8](data))) }

    init(bytes b: ArraySlice<UInt8>) {
        var i = b.startIndex
        let end = b.endIndex

        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < end, shift < 64 {
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < end {
            guard let key = varint() else { break }
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                guard let v = varint() else { return }
                value = .varint(v)
            case 1:
                guard i + 8 <= end else { return }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                i += 8
                value = .fixed64(v)
            case 2:
                guard let len = varint(), len <= UInt64(end - i) else { return }
                value = .bytes(b[i..<(i + Int(len))])
                i += Int(len)
            case 5:
                guard i + 4 <= end else { return }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(b[i + k]) << UInt32(8 * k) }
                i += 4
                value = .fixed32(v)
            default:
                return
            }
            fields[field, default: []].append(value)
        }
    }

    var isEmpty: Bool { fields.isEmpty }
    func has(_ f: Int) -> Bool { fields[f] != nil }

    func uint(_ f: Int) -> UInt64? {
        guard let v = fields[f]?.last else { return nil }
        switch v {
        case .varint(let x): return x
        case .fixed32(let x): return UInt64(x)
        case .fixed64(let x): return x
        case .bytes: return nil
        }
    }

    func int(_ f: Int) -> Int? { uint(f).map { Int(Int64(bitPattern: $0)) } }
    func bool(_ f: Int) -> Bool { (uint(f) ?? 0) != 0 }

    func float(_ f: Int) -> Double? {
        guard let v = fields[f]?.last else { return nil }
        switch v {
        case .fixed32(let x): return Double(Float(bitPattern: x))
        case .fixed64(let x): return Double(bitPattern: x)
        default: return nil
        }
    }

    func string(_ f: Int) -> String? {
        guard case .bytes(let s)? = fields[f]?.last else { return nil }
        let str = String(decoding: s, as: UTF8.self)
        return str.isEmpty ? nil : str
    }

    func bytes(_ f: Int) -> [UInt8]? {
        guard case .bytes(let s)? = fields[f]?.last else { return nil }
        return Array(s)
    }

    func strings(_ f: Int) -> [String] {
        (fields[f] ?? []).compactMap {
            if case .bytes(let s) = $0 { return String(decoding: s, as: UTF8.self) }
            return nil
        }
    }

    func message(_ f: Int) -> ProtoMessage? {
        guard case .bytes(let s)? = fields[f]?.last else { return nil }
        return ProtoMessage(bytes: s)
    }

    func messages(_ f: Int) -> [ProtoMessage] {
        (fields[f] ?? []).compactMap {
            if case .bytes(let s) = $0 { return ProtoMessage(bytes: s) }
            return nil
        }
    }

    /// Repeated float, packed or not.
    func floats(_ f: Int) -> [Float] {
        var out: [Float] = []
        for v in fields[f] ?? [] {
            switch v {
            case .fixed32(let x):
                out.append(Float(bitPattern: x))
            case .bytes(let s):
                out.reserveCapacity(out.count + s.count / 4)
                var i = s.startIndex
                while i + 4 <= s.endIndex {
                    let bits = UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24
                    out.append(Float(bitPattern: bits))
                    i += 4
                }
            default:
                break
            }
        }
        return out
    }
}

enum ProtoWriter {
    static func varint(_ value: UInt64) -> [UInt8] {
        var n = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(n & 0x7f)
            n >>= 7
            out.append(n == 0 ? byte : byte | 0x80)
        } while n != 0
        return out
    }

    /// A length-delimited field wrapping `body`.
    static func field(_ number: Int, body: [UInt8] = []) -> [UInt8] {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(body.count)) + body
    }
}
