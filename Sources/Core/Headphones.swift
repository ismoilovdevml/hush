// Headphones — observable state for the panel, backed by SonyLink.
import Foundation
import Combine
import IOBluetooth

@MainActor
final class Headphones: ObservableObject {
    enum ANC: String, CaseIterable, Identifiable {
        case off, noiseCancelling, ambient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .noiseCancelling: return "Noise Cancelling"
            case .ambient: return "Ambient Sound"
            }
        }
        var short: String {
            switch self {
            case .off: return "Off"
            case .noiseCancelling: return "Noise\nCancelling"
            case .ambient: return "Ambient\nSound"
            }
        }
        var symbol: String {
            switch self {
            case .off: return "nosign"
            case .noiseCancelling: return "waveform.slash"
            case .ambient: return "ear.and.waveform"
            }
        }
    }

    @Published var connected = false
    @Published var name = "WH-1000XM6"
    @Published var battery: Int?
    @Published var charging = false
    @Published var codec = "—"
    @Published var firmware = "—"
    @Published var anc: ANC = .off
    @Published var ambientLevel: Double = 10
    @Published var focusOnVoice = false
    @Published var dsee = false
    @Published var volume: Double = 50
    @Published var mediaKeysAllowed = true
    @Published var eqPreset: UInt8 = 0x00
    @Published var eqBands: [Int] = Array(repeating: 0, count: 10)

    /// Band centre frequencies, read from the device (0x5A) — 10 octave bands on the XM6.
    static let eqFrequencies = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    /// Presets the XM6 reports in its capability reply (0x51).
    static let eqPresets: [(code: UInt8, name: String)] = [
        (0x00, "Off"), (0x30, "Heavy"), (0x31, "Clear"), (0x32, "Hard"),
        (0x33, "Soft"), (0x20, "Gaming"), (0xA0, "Manual"), (0xA1, "User 1"), (0xA2, "User 2"),
    ]
    /// levelSteps is 13, so values travel the wire as dB + 6.
    private static let eqCenter = 6
    var eqIsManual: Bool { eqPreset >= 0xA0 }
    @Published var busy = false

    private let link: SonyLink
    private var poll: Timer?

    init(address: String) {
        link = SonyLink(address: address)
        link.onState = { [weak self] s in
            Task { @MainActor in self?.connected = (s == .online) }
        }
        link.onNotify = { [weak self] f in
            Task { @MainActor in self?.apply(f) }
        }
        volume = SystemVolume.get()
        mediaKeysAllowed = MediaKeyAuth.trusted
        SystemVolume.observe { [weak self] in
            Task { @MainActor in self?.volume = SystemVolume.get() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: reads

    func refresh(completion: (() -> Void)? = nil) {
        guard link.connect() else { connected = false; completion?(); return }
        connected = true
        volume = SystemVolume.get()
        mediaKeysAllowed = MediaKeyAuth.trusted

        link.request(Sony.cmd1, [0x04, 0x02], expect: 0x05) { [weak self] f in
            guard let f, f.payload.count > 3 else { return }
            let s = String(decoding: f.payload.dropFirst(3), as: UTF8.self)
            Task { @MainActor in self?.firmware = s }
        }
        link.request(Sony.cmd1, [0x22, 0x00], expect: 0x23) { [weak self] f in
            guard let f, f.payload.count >= 4 else { return }
            Task { @MainActor in self?.battery = Int(f.payload[2]); self?.charging = f.payload[3] == 1 }
        }
        link.request(Sony.cmd1, [0x12, 0x02], expect: 0x13) { [weak self] f in
            guard let f, f.payload.count >= 3 else { return }
            let names: [UInt8: String] = [0x01: "SBC", 0x02: "AAC", 0x10: "LDAC", 0x20: "aptX", 0x21: "aptX HD"]
            let v = names[f.payload[2]] ?? String(format: "0x%02x", f.payload[2])
            Task { @MainActor in self?.codec = v }
        }
        link.request(Sony.cmd1, [0x66, 0x19], expect: 0x67) { [weak self] f in
            guard let f else { return }
            Task { @MainActor in self?.apply(f) }
        }
        link.request(Sony.cmd1, [0x56, 0x00], expect: 0x57) { [weak self] f in
            guard let f, f.payload.count >= 4 else { return }
            let n = Int(f.payload[3])
            guard f.payload.count >= 4 + n else { return }
            let preset = f.payload[2]
            let bands = f.payload.dropFirst(4).prefix(n).map { Int($0) - Headphones.eqCenter }
            Task { @MainActor in self?.eqPreset = preset; self?.eqBands = Array(bands) }
        }
        // last in the queue, so its completion means every read above has landed
        link.request(Sony.cmd1, [0xE6, 0x01], expect: 0xE7) { [weak self] f in
            Task { @MainActor in
                if let f, f.payload.count >= 3 { self?.dsee = f.payload[2] == 1 }
                completion?()
            }
        }
    }

    /// Decode an ambient-sound RET (0x67) or NOTIFY (0x69).
    /// Layout on XM6: [op, 0x19, 0x01, on, ambientFlag, focusOnVoice, level, 0x00, 0x00]
    private func apply(_ f: SonyFrame) {
        guard f.opcode == 0x67 || f.opcode == 0x69, f.payload.count >= 7, f.payload[1] == 0x19 else { return }
        anc = f.payload[3] == 0 ? .off : (f.payload[4] == 1 ? .ambient : .noiseCancelling)
        focusOnVoice = f.payload[5] == 1
        ambientLevel = Double(min(f.payload[6], 20))
    }

    // MARK: writes

    func setANC(_ mode: ANC, completion: (() -> Void)? = nil) {
        anc = mode
        pushANC(completion: completion)
    }

    func pushANC(completion: (() -> Void)? = nil) {
        busy = true
        let on: UInt8 = anc == .off ? 0 : 1
        let ambientFlag: UInt8 = anc == .ambient ? 1 : 0
        let payload: [UInt8] = [0x68, 0x19, 0x01, on, ambientFlag,
                                focusOnVoice ? 1 : 0, UInt8(ambientLevel.rounded())]
        link.request(Sony.cmd1, payload, expect: 0x69) { [weak self] f in
            Task { @MainActor in
                self?.busy = false
                if let f { self?.apply(f) }
                completion?()
            }
        }
    }

    func setEQPreset(_ preset: UInt8, completion: (() -> Void)? = nil) {
        eqPreset = preset
        link.request(Sony.cmd1, [0x58, 0x00, preset, 0x00], expect: 0x59) { [weak self] f in
            Task { @MainActor in
                if let f { self?.applyEQ(f) }
                completion?()
            }
        }
    }

    func pushEQBands(completion: (() -> Void)? = nil) {
        eqPreset = 0xA0
        let payload: [UInt8] = [0x58, 0x00, 0xA0, UInt8(eqBands.count)]
            + eqBands.map { UInt8(min(max($0, -6), 6) + Headphones.eqCenter) }
        link.request(Sony.cmd1, payload, expect: 0x59) { [weak self] f in
            Task { @MainActor in
                if let f { self?.applyEQ(f) }
                completion?()
            }
        }
    }

    /// Developer escape hatch: send one frame and hand back whatever comes in reply.
    /// Still subject to the opcode allow list in SonyLink.
    func sendRaw(dataType: UInt8, payload: [UInt8], expect: UInt8,
                 completion: @escaping ([UInt8]?) -> Void) {
        link.request(dataType, payload, expect: expect) { f in
            Task { @MainActor in completion(f?.payload) }
        }
    }

    private func applyEQ(_ f: SonyFrame) {
        guard f.payload.count >= 4 else { return }
        let n = Int(f.payload[3])
        guard f.payload.count >= 4 + n else { return }
        eqPreset = f.payload[2]
        eqBands = f.payload.dropFirst(4).prefix(n).map { Int($0) - Headphones.eqCenter }
    }

    func setDSEE(_ on: Bool, completion: (() -> Void)? = nil) {
        dsee = on
        link.request(Sony.cmd1, [0xE8, 0x01, on ? 1 : 0], expect: 0xE9) { _ in
            Task { @MainActor in completion?() }
        }
    }

    func setVolume(_ v: Double) {
        volume = v
        SystemVolume.set(v)
    }
}
