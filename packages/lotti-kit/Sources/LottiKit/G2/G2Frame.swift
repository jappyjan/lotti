/// The G2 transport envelope. Every write to and notification from the glasses' control
/// characteristic is one of these packets:
///
///     AA <dir> <seq> <len> <total> <num> <sid> <flag> <chunk…> [CRC16 LE, last packet only]
///
/// - dir:   0x21 phone → glasses, 0x12 glasses → phone
/// - seq:   message id. Every packet of one message carries the SAME seq (it's the reassembly key)
/// - len:   bytes after the 8-byte header in this packet, CRC included
/// - total/num: packet count and 1-based packet number
/// - sid:   service id (which subsystem on the glasses handles the payload)
/// - flag:  0x20 for most app → glasses requests, 0x00 for device config (sid 0x80)
/// - CRC:   CRC-16/CCITT-FALSE over the whole payload (all chunks), little-endian
///
/// Sources: g2-kit `ble/envelope.ts`, even-g2-protocol `widgets/evenhub.py`, MentraOS `G2.swift`.
public enum G2Frame {
    public static let header: UInt8 = 0xAA
    public static let toGlasses: UInt8 = 0x21
    public static let fromGlasses: UInt8 = 0x12
    public static let headerLength = 8
    /// Largest chunk the firmware is known to accept in one packet (MentraOS uses 236).
    public static let maxChunk = 232

    /// Splits `payload` into packets. `maxPacketSize` is the BLE write size limit
    /// (`maximumWriteValueLength(for: .withoutResponse)` on iOS).
    public static func encode(
        payload: [UInt8], sid: UInt8, flag: UInt8, seq: UInt8, maxPacketSize: Int = 244
    ) -> [[UInt8]] {
        // Keep room for the header and the CRC so the CRC always lands whole in the last packet.
        let chunkSize = max(1, min(maxChunk, maxPacketSize - headerLength - 2))
        var chunks: [ArraySlice<UInt8>] = stride(from: 0, to: payload.count, by: chunkSize).map {
            payload[$0..<min($0 + chunkSize, payload.count)]
        }
        if chunks.isEmpty { chunks = [[]] }

        let crc = CRC16.ccittFalse(payload)
        let total = UInt8(chunks.count)
        return chunks.enumerated().map { index, chunk in
            let isLast = index == chunks.count - 1
            var packet: [UInt8] = [
                header, toGlasses, seq, UInt8(chunk.count + (isLast ? 2 : 0)),
                total, UInt8(index + 1), sid, flag,
            ]
            packet.append(contentsOf: chunk)
            if isLast {
                packet.append(UInt8(crc & 0xFF))
                packet.append(UInt8(crc >> 8))
            }
            return packet
        }
    }
}

/// One complete message from the glasses, after reassembly.
public struct G2Message: Equatable, Sendable {
    public var sid: UInt8
    public var flag: UInt8
    public var seq: UInt8
    public var payload: [UInt8]

    /// Field 2 of the payload. Replies echo the "magic" of the request they answer.
    public var magic: UInt64? { ProtoReader.varintFields(payload)[2] }
    /// Field 1 of the payload: the command id for most services.
    public var command: UInt64 { ProtoReader.varintFields(payload)[1] ?? 0 }
}

/// Joins multi-packet notifications back into whole messages. One per arm.
public struct G2FrameAssembler: Sendable {
    private var partial: [UInt16: (next: UInt8, bytes: [UInt8])] = [:]
    public private(set) var crcErrors = 0

    public init() {}

    /// Feed one BLE notification. Returns a message once its last packet arrived, else nil.
    public mutating func feed(_ packet: [UInt8]) -> G2Message? {
        guard packet.count >= G2Frame.headerLength + 2, packet[0] == G2Frame.header else { return nil }
        let seq = packet[2], len = Int(packet[3]), total = packet[4], num = packet[5]
        let sid = packet[6], flag = packet[7]
        let end = min(packet.count, G2Frame.headerLength + len)
        let chunk = Array(packet[G2Frame.headerLength..<end])
        let key = UInt16(sid) << 8 | UInt16(seq)

        var body: [UInt8]
        if total <= 1 {
            body = chunk
        } else if num == 1 {
            partial[key] = (2, chunk)
            return nil
        } else if let part = partial[key], part.next == num {
            body = part.bytes + chunk
            if num < total {
                partial[key] = (num + 1, body)
                return nil
            }
            partial[key] = nil
        } else {
            partial[key] = nil  // gap or out of order: drop the message
            return nil
        }

        guard body.count >= 2 else { return nil }
        let payload = Array(body.dropLast(2))
        let crc = UInt16(body[body.count - 2]) | UInt16(body[body.count - 1]) << 8
        if crc != CRC16.ccittFalse(payload) { crcErrors += 1 }
        return G2Message(sid: sid, flag: flag, seq: seq, payload: payload)
    }
}

public enum CRC16 {
    /// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
    public static func ccittFalse<C: Collection<UInt8>>(_ data: C) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
