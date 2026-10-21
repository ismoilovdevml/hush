// The wire format, on its own so it can be tested without a headset.
//
// It is pulled out of SonyLink deliberately: the one bug that cost a day here was a
// single wrong bit in the escape mask, and it was invisible until a payload happened to
// carry 0x3E. That is exactly the kind of thing a test pins down.
import Foundation

enum SonyFrameCodec {
    /// Frame: 0x3E | dataType | seq | length (4B BE) | payload | checksum | 0x3C
    /// checksum = sum(dataType ... payload) & 0xFF.
    /// 0x3E / 0x3D / 0x3C inside the frame are escaped as 0x3D then `b & 0xEF`
    /// (bit 4 cleared); the reader restores them with `b | 0x10`.
    static func encode(dataType: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        var body: [UInt8] = [
            dataType, seq,
            UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff),
        ]
        body += payload
        body.append(checksum(of: body))

        var out: [UInt8] = [Sony.start]
        for b in body {
            if b == Sony.start || b == Sony.end || b == Sony.esc {
                out += [Sony.esc, b & ~Sony.escapeBit]
            } else {
                out.append(b)
            }
        }
        out.append(Sony.end)
        return out
    }

    static func checksum(of body: [UInt8]) -> UInt8 {
        UInt8(body.reduce(0) { $0 + Int($1) } & 0xff)
    }

    /// Pulls every complete frame out of `buffer`, consuming what it reads and leaving any
    /// partial tail behind. Frames that fail their checksum or whose declared length does not
    /// match are dropped rather than passed on.
    static func decode(from buffer: inout [UInt8]) -> [SonyFrame] {
        var frames: [SonyFrame] = []

        while let start = buffer.firstIndex(of: Sony.start) {
            var body: [UInt8] = []
            var i = start + 1
            var sawEnd = false

            while i < buffer.count {
                if buffer[i] == Sony.end { sawEnd = true; break }
                if buffer[i] == Sony.esc {
                    i += 1
                    if i < buffer.count { body.append(buffer[i] | Sony.escapeBit) }
                } else {
                    body.append(buffer[i])
                }
                i += 1
            }

            guard sawEnd else {
                // keep the partial frame, drop whatever preceded it
                if start > 0 { buffer.removeSubrange(0..<start) }
                return frames
            }
            buffer.removeSubrange(0...i)

            guard body.count >= 7 else { continue }
            guard checksum(of: Array(body.dropLast())) == body[body.count - 1] else { continue }

            let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
            guard length == body.count - 7 else { continue }

            frames.append(SonyFrame(dataType: body[0], seq: body[1],
                                    payload: Array(body[6..<(6 + length)])))
        }
        return frames
    }
}
