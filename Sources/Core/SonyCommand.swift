// Payload construction and parsing, kept free of Bluetooth so it can be tested directly.
import Foundation

enum SonyCommand {
    // MARK: ambient sound control
    //
    // The inquiry type is NOT 0x15 or 0x17 on the WH-1000XM6, whatever Gadgetbridge assumes:
    // 0x15 and 0x22 draw no reply at all, and 0x17 answers once with a stale all-zero payload
    // that never tracks the real state. Only 0x19 round-trips. Other models may differ, so the
    // type is a parameter and SonyLink probes for it.
    static let ambientTypes: [UInt8] = [0x19, 0x17, 0x15, 0x22]

    enum AmbientMode: Equatable { case off, noiseCancelling, ambient }

    static func ambientGet(type: UInt8) -> [UInt8] { [0x66, type] }

    static func ambientSet(type: UInt8, mode: AmbientMode,
                           focusOnVoice: Bool, level: Int) -> [UInt8] {
        [0x68, type, 0x01,
         mode == .off ? 0 : 1,
         mode == .ambient ? 1 : 0,
         focusOnVoice ? 1 : 0,
         UInt8(min(max(level, 0), 20))]
    }

    /// Parses a 0x67 reply or a 0x69 notification.
    /// Layout: [opcode, type, 0x01, on, ambientFlag, focusOnVoice, level, 0x00, 0x00]
    static func parseAmbient(_ payload: [UInt8])
        -> (mode: AmbientMode, focusOnVoice: Bool, level: Int)? {
        guard payload.count >= 7, payload[0] == 0x67 || payload[0] == 0x69 else { return nil }
        let mode: AmbientMode = payload[3] == 0 ? .off : (payload[4] == 1 ? .ambient : .noiseCancelling)
        return (mode, payload[5] == 1, Int(min(payload[6], 20)))
    }

    // MARK: equalizer
    //
    // The headphones describe their own equalizer: 0x50 reports band count and level steps,
    // 0x5A reports the centre frequencies. On the XM6 that is 10 bands and 13 steps, so the
    // centre is 6 and a band travels the wire as dB + 6, range -6...+6. A flat curve therefore
    // reads back as ten 0x06 bytes.
    static let equalizerTypes: [UInt8] = [0x00, 0x02, 0x04, 0x03]
    static let manualPreset: UInt8 = 0xA0

    static func center(levelSteps: UInt8) -> Int { (Int(levelSteps) - 1) / 2 }

    static func equalizerGet(type: UInt8) -> [UInt8] { [0x56, type] }
    static func equalizerCapabilityGet(type: UInt8) -> [UInt8] { [0x50, type, 0x01] }
    static func equalizerBandsGet(type: UInt8) -> [UInt8] { [0x5A, type] }

    static func equalizerPresetSet(type: UInt8, preset: UInt8) -> [UInt8] {
        [0x58, type, preset, 0x00]
    }

    static func equalizerBandsSet(type: UInt8, bands: [Int], center: Int = 6) -> [UInt8] {
        [0x58, type, manualPreset, UInt8(bands.count)]
            + bands.map { UInt8(min(max($0, -center), center) + center) }
    }

    /// Parses a 0x57 reply or a 0x59 notification: [opcode, type, preset, count, values...]
    static func parseEqualizer(_ payload: [UInt8], center: Int = 6)
        -> (preset: UInt8, bands: [Int])? {
        guard payload.count >= 4, payload[0] == 0x57 || payload[0] == 0x59 else { return nil }
        let count = Int(payload[3])
        guard payload.count >= 4 + count else { return nil }
        return (payload[2], payload[4..<(4 + count)].map { Int($0) - center })
    }

    /// Parses the 0x51 capability reply: [0x51, ?, bandCount, levelSteps, presetCount, ...]
    static func parseEqualizerCapability(_ payload: [UInt8])
        -> (bandCount: Int, levelSteps: UInt8, presets: [UInt8])? {
        guard payload.count >= 5, payload[0] == 0x51 else { return nil }
        var presets: [UInt8] = []
        var offset = 5
        for _ in 0..<Int(payload[4]) {
            guard offset + 1 < payload.count else { return nil }
            presets.append(payload[offset])
            offset += 2 + Int(payload[offset + 1])
        }
        return (Int(payload[2]), payload[3], presets)
    }

    /// Parses the 0x5B band table: [0x5B, type, count, (unit, hi, lo) * count]
    static func parseEqualizerFrequencies(_ payload: [UInt8]) -> [Int]? {
        guard payload.count >= 3, payload[0] == 0x5B else { return nil }
        let count = Int(payload[2])
        guard payload.count >= 3 + count * 3 else { return nil }
        return (0..<count).map { i in
            let base = 3 + i * 3
            return Int(payload[base + 1]) << 8 | Int(payload[base + 2])
        }
    }

    /// Human label for a frequency in Hz, as the panel and the CLI print it.
    static func frequencyLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000)k" : "\(hz)"
    }
}
