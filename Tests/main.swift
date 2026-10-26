// Tests for the wire format and the payload encodings. No headphones involved.
// Run with ./test.sh — CI runs it on every push.
import Foundation

var failures = 0
var checks = 0

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if passed {
        print("  ok    \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL  \(name)" + (extra.isEmpty ? "" : "\n          \(extra)"))
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func bytes(_ string: String) -> [UInt8] {
    string.split(separator: " ").compactMap { UInt8($0, radix: 16) }
}

print("frame codec")

// A frame with nothing special in it should survive the round trip untouched.
do {
    let payload: [UInt8] = [0x22, 0x00]
    var wire = SonyFrameCodec.encode(dataType: 0x0C, seq: 0, payload: payload)
    let frames = SonyFrameCodec.decode(from: &wire)
    check("plain payload round-trips", frames.count == 1 && frames[0].payload == payload,
          "got \(frames.map { hex($0.payload) })")
    check("buffer is fully consumed", wire.isEmpty, "left \(hex(wire))")
}

// The regression: 0x3E, 0x3D and 0x3C must be escaped with bit 4 cleared, not bit 5.
// Clearing the wrong bit stays invisible until a payload happens to carry one of them.
do {
    let payload: [UInt8] = [0x5B, 0x3E, 0x3D, 0x3C, 0x80]
    var wire = SonyFrameCodec.encode(dataType: 0x0C, seq: 1, payload: payload)
    check("0x3E is escaped as 3d 2e", hex(wire).contains("3d 2e"), hex(wire))
    check("0x3D is escaped as 3d 2d", hex(wire).contains("3d 2d"), hex(wire))
    check("0x3C is escaped as 3d 2c", hex(wire).contains("3d 2c"), hex(wire))
    let frames = SonyFrameCodec.decode(from: &wire)
    check("escaped payload round-trips", frames.count == 1 && frames[0].payload == payload,
          "got \(frames.map { hex($0.payload) })")
}

// The checksum byte is escaped too. dataType 0x0C, seq 0, payload [0x31] sums to exactly 0x3E,
// which is the start marker — getting this wrong means the headphones silently drop the command.
do {
    let wire = SonyFrameCodec.encode(dataType: 0x0C, seq: 0, payload: [0x31])
    check("a checksum of 0x3E is escaped", hex(wire).hasSuffix("3d 2e 3c"), hex(wire))
    var copy = wire
    let frames = SonyFrameCodec.decode(from: &copy)
    check("a frame with an escaped checksum decodes", frames.count == 1 && frames[0].payload == [0x31])
}

// The real reply that exposed the bug: the equalizer band table, where 16000 Hz is 0x3E80.
do {
    var wire = bytes("""
        3e 0c 01 00 00 00 21 5b 00 0a 01 00 1f 01 00 3f 01 00 7d 01 00 fa 01 01 f4 \
        01 03 e8 01 07 d0 01 0f a0 01 1f 40 01 3d 2e 80 f5 3c
        """)
    let frames = SonyFrameCodec.decode(from: &wire)
    check("the captured band table decodes", frames.count == 1, "got \(frames.count) frames")
    let freqs = frames.first.flatMap { SonyCommand.parseEqualizerFrequencies($0.payload) }
    check("ten bands, 31 Hz to 16 kHz",
          freqs == [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
          "got \(freqs ?? [])")
}

// Corrupt and malformed frames must be dropped, not handed upwards.
do {
    var wire = SonyFrameCodec.encode(dataType: 0x0C, seq: 0, payload: [0x22, 0x00])
    wire[wire.count - 2] = wire[wire.count - 2] &+ 1          // break the checksum
    check("a bad checksum is dropped", SonyFrameCodec.decode(from: &wire).isEmpty)

    var wrongLength = bytes("3e 0c 00 00 00 00 09 22 00 37 3c")  // says 9 bytes, carries 2
    check("a wrong length is dropped", SonyFrameCodec.decode(from: &wrongLength).isEmpty)
}

// Bluetooth hands over arbitrary chunks, so a frame may arrive in pieces.
do {
    let wire = SonyFrameCodec.encode(dataType: 0x0C, seq: 0, payload: [0x66, 0x19])
    var buffer = Array(wire.prefix(4))
    check("a partial frame yields nothing yet", SonyFrameCodec.decode(from: &buffer).isEmpty)
    buffer += wire.dropFirst(4)
    check("the rest completes it", SonyFrameCodec.decode(from: &buffer).count == 1)

    var noisy: [UInt8] = [0xAA, 0xBB] + wire + wire
    check("leading noise is skipped and both frames come back",
          SonyFrameCodec.decode(from: &noisy).count == 2)
}

print("\nambient sound control")

do {
    let payload = SonyCommand.ambientSet(type: 0x19, mode: .ambient, focusOnVoice: true, level: 12)
    check("ambient set builds 68 19 01 01 01 01 0c", hex(payload) == "68 19 01 01 01 01 0c", hex(payload))

    check("off encodes on=0", SonyCommand.ambientSet(type: 0x19, mode: .off, focusOnVoice: false, level: 0)[3] == 0)
    check("noise cancelling is on=1 ambient=0",
          Array(SonyCommand.ambientSet(type: 0x19, mode: .noiseCancelling, focusOnVoice: false, level: 0)[3...4]) == [1, 0])
    check("the level is clamped to 20",
          SonyCommand.ambientSet(type: 0x19, mode: .ambient, focusOnVoice: false, level: 99)[6] == 20)

    let parsed = SonyCommand.parseAmbient(bytes("67 19 01 01 01 01 0c 00 00"))
    check("a reply parses back", parsed?.mode == .ambient && parsed?.focusOnVoice == true && parsed?.level == 12,
          String(describing: parsed))
    check("a notification parses too", SonyCommand.parseAmbient(bytes("69 19 01 01 00 00 08 00 00"))?.mode == .noiseCancelling)
    check("an unrelated opcode is refused", SonyCommand.parseAmbient(bytes("57 00 00 0a")) == nil)
}

print("\nequalizer")

do {
    // levelSteps 13 puts the centre at 6, so flat is ten bytes of 0x06
    check("13 level steps centre on 6", SonyCommand.center(levelSteps: 13) == 6)

    let flat = SonyCommand.parseEqualizer(bytes("57 00 00 0a 06 06 06 06 06 06 06 06 06 06"))
    check("a flat curve reads as all zeros", flat?.bands == Array(repeating: 0, count: 10),
          String(describing: flat?.bands))
    check("the preset comes through", flat?.preset == 0x00)

    let curve = [4, 3, 1, 0, -1, 0, 1, 2, 4, 5]
    let payload = SonyCommand.equalizerBandsSet(type: 0x00, bands: curve)
    check("a manual curve is sent as dB + 6",
          hex(payload) == "58 00 a0 0a 0a 09 07 06 05 06 07 08 0a 0b", hex(payload))
    let round = SonyCommand.parseEqualizer([0x57, 0x00, 0xA0] + payload.dropFirst(3))
    check("and parses back to the same curve", round?.bands == curve, String(describing: round?.bands))

    check("bands are clamped to the range",
          SonyCommand.equalizerBandsSet(type: 0x00, bands: [99, -99]).dropFirst(4).map { Int($0) } == [12, 0])

    let capability = SonyCommand.parseEqualizerCapability(
        bytes("51 04 0a 0d 09 00 00 30 00 31 00 32 00 33 00 20 00 a0 00 a1 00 a2 00"))
    check("the capability reply gives 10 bands and 13 steps",
          capability?.bandCount == 10 && capability?.levelSteps == 13,
          String(describing: capability))
    check("and nine presets including Manual",
          capability?.presets == [0x00, 0x30, 0x31, 0x32, 0x33, 0x20, 0xA0, 0xA1, 0xA2],
          String(describing: capability?.presets))

    check("frequency labels read like the UI",
          [31, 500, 1000, 16000].map(SonyCommand.frequencyLabel) == ["31", "500", "1k", "16k"])
}

print("\nbattery")

do {
    check("charging wins over the level", BatteryLevel.of(percent: 5, charging: true) == .charging)
    check("20% and below is critical", BatteryLevel.of(percent: 20, charging: false) == .critical)
    check("21% is no longer critical", BatteryLevel.of(percent: 21, charging: false) == .low)
    check("35% is still low", BatteryLevel.of(percent: 35, charging: false) == .low)
    check("36% is normal", BatteryLevel.of(percent: 36, charging: false) == .normal)
    check("full is normal", BatteryLevel.of(percent: 100, charging: false) == .normal)

    check("charging shows the bolt", BatteryLevel.symbol(percent: 50, charging: true) == "battery.100.bolt")
    check("an empty battery shows the empty glyph", BatteryLevel.symbol(percent: 5, charging: false) == "battery.0")
    check("a full battery shows the full glyph", BatteryLevel.symbol(percent: 95, charging: false) == "battery.100")
}

print("\nopcode policy")

do {
    for opcode in [0x98, 0x24, 0x2D, 0xC4] as [UInt8] {
        check(String(format: "0x%02X is denied", opcode),
              Sony.forbidden.contains(opcode) && !Sony.allowed.contains(opcode))
        check(String(format: "0x%02X is refused by permits", opcode), !Sony.permits([opcode]))
    }
    check("the lists do not overlap", Sony.allowed.isDisjoint(with: Sony.forbidden))
    check("ambient and equalizer writes are allowed",
          Sony.allowed.contains(0x68) && Sony.allowed.contains(0x58))

    // SYSTEM_SET_PARAM (0xF8) is type-aware: speak-to-chat only, never factory reset (0x09).
    check("0xF8 is not blanket-allowed", !Sony.allowed.contains(0xF8))
    check("a bare 0xF8 is refused", !Sony.permits([0xF8]))
    check("0xF8 + RESET_SETTINGS (0x09) is refused", !Sony.permits([0xF8, 0x09]))
    check("0xF8 + an unrelated system type is refused", !Sony.permits([0xF8, 0x03]))
    check("0xF8 + SMART_TALKING_MODE_TYPE1 (0x02) is permitted", Sony.permits([0xF8, 0x02]))
    check("0xF8 + SMART_TALKING_MODE_TYPE2 (0x0C) is permitted", Sony.permits([0xF8, 0x0C]))
    check("the factory-reset type is not a speak-to-chat type", !Sony.smartTalkingTypes.contains(0x09))
    check("ambient and equalizer writes still clear permits",
          Sony.permits([0x68, 0x19]) && Sony.permits([0x58, 0x00, 0xA0, 0x0A]))
}

print("\nspeak-to-chat + noise-adaptive ANC")

do {
    check("STC get is [0xF6, type]", SonyCommand.smartTalkingGet(type: 0x02) == [0xF6, 0x02])
    check("STC config get is [0xFA, type]", SonyCommand.smartTalkingConfigGet(type: 0x0C) == [0xFA, 0x0C])
    // On/off is inverted on the wire: enabling writes 0x00.
    check("STC enable writes 0x00 (inverted)",
          SonyCommand.smartTalkingSet(type: 0x02, enabled: true) == [0xF8, 0x02, 0x00, 0x00])
    check("STC disable writes 0x01",
          SonyCommand.smartTalkingSet(type: 0x02, enabled: false) == [0xF8, 0x02, 0x01, 0x01])
    check("STC config TYPE1 has the voice-focus byte",
          SonyCommand.smartTalkingConfigSet(type: 0x02, sensitivity: .high,
                                             modeOutTime: .slow, voiceFocus: true) == [0xFC, 0x02, 0x01, 0x00, 0x02])
    check("STC config TYPE2 drops the voice-focus byte",
          SonyCommand.smartTalkingConfigSet(type: 0x0C, sensitivity: .low,
                                             modeOutTime: .keepUntilStopped) == [0xFC, 0x0C, 0x02, 0x03])
    check("STC reply parses inverted enabled",
          SonyCommand.parseSmartTalking([0xF7, 0x02, 0x00, 0x00])?.enabled == true)
    check("STC reply parses disabled",
          SonyCommand.parseSmartTalking([0xF7, 0x02, 0x01, 0x01])?.enabled == false)

    // The 0x19 noise-adaptive ANC frame is 9 bytes: 7-byte core + adaptive on/off + sensitivity.
    check("adaptive ANC SET is the 9-byte 0x19 frame",
          SonyCommand.ambientSetAdaptive(mode: .noiseCancelling, focusOnVoice: false, level: 10,
                                         adaptiveOn: true, sensitivity: .standard)
          == [0x68, 0x19, 0x01, 1, 0, 0, 10, 1, 0])
    check("adaptive ANC ambient+voice+sensitivity encodes",
          SonyCommand.ambientSetAdaptive(mode: .ambient, focusOnVoice: true, level: 20,
                                         adaptiveOn: false, sensitivity: .low)
          == [0x68, 0x19, 0x01, 1, 1, 1, 20, 0, 2])

    // Guard: the extended-config opcode is type-gated just like 0xF8, and reset stays unreachable.
    check("0xF8 + speak-to-chat type is permitted", Sony.permits([0xF8, 0x02]) && Sony.permits([0xF8, 0x0C]))
    check("0xFC + speak-to-chat type is permitted", Sony.permits([0xFC, 0x02]) && Sony.permits([0xFC, 0x0C]))
    check("0xFC + RESET_SETTINGS (0x09) is refused", !Sony.permits([0xFC, 0x09]))
    check("a bare 0xFC is refused", !Sony.permits([0xFC]))
    check("0xFC is not blanket-allowed", !Sony.allowed.contains(0xFC))
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
