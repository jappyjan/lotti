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

/// Reads the fields of a protobuf message: enough to pull the command id (field 1) and magic
/// (field 2) out of a reply, and to walk into the nested messages of an event.
enum ProtoReader {
    /// First value of each varint field. Zero values are usually left out on the wire, so a
    /// missing field means 0.
    static func varintFields(_ bytes: [UInt8]) -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        walk(bytes) { field, varint, _ in
            if let varint, result[field] == nil { result[field] = varint }
        }
        return result
    }

    /// First length-delimited field `field` (a nested message, string or bytes), or nil.
    static func message(_ bytes: [UInt8], _ field: Int) -> [UInt8]? {
        var found: [UInt8]?
        walk(bytes) { f, _, data in
            if found == nil, f == field, let data { found = data }
        }
        return found
    }

    /// First value of each 32-bit fixed field (wire type 5), read as a little-endian float.
    static func floatFields(_ bytes: [UInt8]) -> [Int: Float] {
        var result: [Int: Float] = [:]
        walk(bytes, fixed32: { field, bits in
            if result[field] == nil { result[field] = Float(bitPattern: bits) }
        }) { _, _, _ in }
        return result
    }

    static func string(_ bytes: [UInt8], _ field: Int) -> String? {
        message(bytes, field).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Calls `visit` for every field: varints with their value, length-delimited fields with
    /// their bytes. 64-bit fields are skipped, 32-bit ones go to `fixed32` if given. Stops at the
    /// first malformed byte.
    private static func walk(
        _ bytes: [UInt8], fixed32: ((Int, UInt32) -> Void)? = nil, _ visit: (Int, UInt64?, [UInt8]?) -> Void
    ) {
        var i = 0
        while i < bytes.count {
            guard let key = readVarint(bytes, &i) else { return }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint(bytes, &i) else { return }
                visit(field, v, nil)
            case 1: i += 8
            case 2:
                guard let len = readVarint(bytes, &i).flatMap({ Int(exactly: $0) }), len <= bytes.count - i
                else { return }
                visit(field, nil, Array(bytes[i..<i + len]))
                i += len
            case 5:
                guard i + 4 <= bytes.count else { return }
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << (8 * $1) }
                fixed32?(field, bits)
                i += 4
            default: return
            }
        }
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
