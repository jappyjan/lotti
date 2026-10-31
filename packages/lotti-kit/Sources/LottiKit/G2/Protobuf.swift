/// Just enough protobuf to talk to the G2. The glasses' messages are small and hand-built, so a
/// full protobuf runtime would be overkill. Unlike proto3 defaults, zero values are written when
/// asked for: the firmware expects some of them on the wire (e.g. x = 0, y = 0).
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        Self.appendVarint(value, to: &bytes)
    }

    mutating func varint(_ field: Int, _ value: Int) {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: [UInt8]) {
        key(field, wireType: 2)
        Self.appendVarint(UInt64(value.count), to: &bytes)
        bytes.append(contentsOf: value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Array(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.bytes)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        Self.appendVarint(UInt64(field) << 3 | wireType, to: &bytes)
    }

    static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }
}

/// Reads the top-level varint fields of a protobuf message. Enough to pull the command id
/// (field 1) and magic (field 2) out of a reply.
enum ProtoReader {
    static func varintFields(_ bytes: [UInt8]) -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        var i = 0
        while i < bytes.count {
            guard let key = readVarint(bytes, &i) else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint(bytes, &i) else { return result }
                if result[field] == nil { result[field] = v }
            case 1: i += 8
            case 2:
                guard let len = readVarint(bytes, &i) else { return result }
                i += Int(len)
            case 5: i += 4
            default: return result
            }
        }
        return result
    }

    static func readVarint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count, shift < 64 {
            let b = bytes[i]
            i += 1
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
