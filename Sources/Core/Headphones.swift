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

    /// Band centre frequencies, asked of the device (0x5A). The XM6 answers with ten octave
    /// bands; another model may answer differently, so this is not hard-coded.
    @Published var eqFrequencies = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    /// Whatever the device lists in its capability reply (0x51), named.
    @Published var eqPresets: [(code: UInt8, name: String)] = Headphones.allPresets

    static let allPresets: [(code: UInt8, name: String)] = [
        (0x00, "Off"), (0x01, "Rock"), (0x02, "Pop"), (0x03, "Jazz"), (0x04, "Dance"),
        (0x05, "EDM"), (0x06, "R&B"), (0x07, "Acoustic"), (0x10, "Bright"), (0x11, "Excited"),
        (0x12, "Mellow"), (0x13, "Relaxed"), (0x14, "Vocal"), (0x15, "Treble Boost"),
        (0x16, "Bass Boost"), (0x17, "Speech"), (0x20, "Gaming"), (0x30, "Heavy"),
        (0x31, "Clear"), (0x32, "Hard"), (0x33, "Soft"), (0xA0, "Manual"),
        (0xA1, "User 1"), (0xA2, "User 2"), (0xA3, "User 3"),
    ]
    var eqIsManual: Bool { eqPreset >= 0xA0 }

    /// Inquiry types differ between models, so they are discovered rather than assumed.
    /// On the XM6 ambient sound answers only on 0x19 — see SonyCommand.
    private var ambientType: UInt8?
    private var eqType: UInt8?
    private var eqCenter = 6
    private var eqBandCount = 10
    @Published var busy = false

    private let link: SonyLink
    private let address: String
    private var poll: Timer?

    init(address: String) {
        self.address = address
        link = SonyLink(address: address)
        link.onState = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.connected = (s == .online)
                if !self.connected { self.battery = nil; self.charging = false }
            }
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
        guard link.connect() else {
            connected = false
            battery = nil
            charging = false
            codec = "—"
            firmware = "—"
            completion?()
            return
        }
        connected = true
        volume = SystemVolume.get()
        mediaKeysAllowed = MediaKeyAuth.trusted

        link.request(Sony.cmd1, [0x04, 0x02], expect: 0x05) { [weak self] f in
            guard let f, f.payload.count > 3 else { return }
            let s = String(decoding: f.payload.dropFirst(3), as: UTF8.self)
            Task { @MainActor in
                self?.firmware = s
                // it answered the Sony protocol, so it is the one worth coming back to
                if let address = self?.address { rememberHeadset(address: address) }
            }
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
        probeAmbientType { [weak self] type in
            guard let self, let type else { return }
            self.link.request(Sony.cmd1, SonyCommand.ambientGet(type: type), expect: 0x67) { f in
                Task { @MainActor in if let f { self.apply(f) } }
            }
        }
        probeEqualizer { [weak self] type in
            guard let self, let type else { return }
            self.link.request(Sony.cmd1, SonyCommand.equalizerGet(type: type), expect: 0x57) { f in
                Task { @MainActor in if let f { self.applyEQ(f) } }
            }
        }
        // last in the queue, so its completion means every read above has landed
        link.request(Sony.cmd1, [0xE6, 0x01], expect: 0xE7) { [weak self] f in
            Task { @MainActor in
                if let f, f.payload.count >= 3 { self?.dsee = f.payload[2] == 1 }
                completion?()
            }
        }
    }

    private func apply(_ f: SonyFrame) {
        guard let parsed = SonyCommand.parseAmbient(f.payload) else { return }
        switch parsed.mode {
        case .off: anc = .off
        case .noiseCancelling: anc = .noiseCancelling
        case .ambient: anc = .ambient
        }
        focusOnVoice = parsed.focusOnVoice
        ambientLevel = Double(parsed.level)
    }

    /// Ask each known inquiry type in turn and keep the one that answers. On the XM6 that is
    /// 0x19; 0x15 and 0x22 stay silent and 0x17 returns a stale all-zero payload, which is why
    /// 0x19 is tried first.
    private func probeAmbientType(_ done: @escaping (UInt8?) -> Void) {
        if let ambientType { return done(ambientType) }
        func attempt(_ remaining: ArraySlice<UInt8>) {
            guard let type = remaining.first else { return done(nil) }
            link.request(Sony.cmd1, SonyCommand.ambientGet(type: type), expect: 0x67) { [weak self] f in
                Task { @MainActor in
                    guard let self else { return }
                    if let f, f.payload.count > 1, f.payload[1] == type {
                        self.ambientType = type
                        done(type)
                    } else {
                        attempt(remaining.dropFirst())
                    }
                }
            }
        }
        attempt(SonyCommand.ambientTypes[...])
    }

    /// The equalizer describes itself: band count, level steps, presets and centre frequencies.
    private func probeEqualizer(_ done: @escaping (UInt8?) -> Void) {
        if let eqType { return done(eqType) }
        func attempt(_ remaining: ArraySlice<UInt8>) {
            guard let type = remaining.first else { return done(nil) }
            link.request(Sony.cmd1, SonyCommand.equalizerCapabilityGet(type: type), expect: 0x51) { [weak self] f in
                Task { @MainActor in
                    guard let self else { return }
                    guard let f, let capability = SonyCommand.parseEqualizerCapability(f.payload) else {
                        return attempt(remaining.dropFirst())
                    }
                    self.eqType = type
                    self.eqCenter = SonyCommand.center(levelSteps: capability.levelSteps)
                    self.eqBandCount = capability.bandCount
                    let names = Dictionary(uniqueKeysWithValues: Headphones.allPresets.map { ($0.code, $0.name) })
                    self.eqPresets = capability.presets.map {
                        ($0, names[$0] ?? String(format: "0x%02X", $0))
                    }
                    self.link.request(Sony.cmd1, SonyCommand.equalizerBandsGet(type: type), expect: 0x5B) { bands in
                        Task { @MainActor in
                            if let bands, let hz = SonyCommand.parseEqualizerFrequencies(bands.payload) {
                                self.eqFrequencies = hz.map(SonyCommand.frequencyLabel)
                            }
                            done(type)
                        }
                    }
                }
            }
        }
        attempt(SonyCommand.equalizerTypes[...])
    }

    // MARK: writes

    func setANC(_ mode: ANC, completion: (() -> Void)? = nil) {
        anc = mode
        pushANC(completion: completion)
    }

    func pushANC(completion: (() -> Void)? = nil) {
        busy = true
        probeAmbientType { [weak self] type in
            guard let self else { return }
            guard let type else { self.busy = false; completion?(); return }
            let mode: SonyCommand.AmbientMode = self.anc == .off ? .off
                : (self.anc == .ambient ? .ambient : .noiseCancelling)
            let payload = SonyCommand.ambientSet(type: type, mode: mode,
                                                 focusOnVoice: self.focusOnVoice,
                                                 level: Int(self.ambientLevel.rounded()))
            self.link.request(Sony.cmd1, payload, expect: 0x69) { f in
                Task { @MainActor in
                    self.busy = false
                    if let f { self.apply(f) }
                    completion?()
                }
            }
        }
    }

    func setEQPreset(_ preset: UInt8, completion: (() -> Void)? = nil) {
        eqPreset = preset
        probeEqualizer { [weak self] type in
            guard let self, let type else { completion?(); return }
            self.link.request(Sony.cmd1,
                              SonyCommand.equalizerPresetSet(type: type, preset: preset),
                              expect: 0x59) { f in
                Task { @MainActor in
                    if let f { self.applyEQ(f) }
                    completion?()
                }
            }
        }
    }

    func pushEQBands(completion: (() -> Void)? = nil) {
        eqPreset = SonyCommand.manualPreset
        probeEqualizer { [weak self] type in
            guard let self, let type else { completion?(); return }
            let payload = SonyCommand.equalizerBandsSet(type: type, bands: self.eqBands,
                                                        center: self.eqCenter)
            self.link.request(Sony.cmd1, payload, expect: 0x59) { f in
                Task { @MainActor in
                    if let f { self.applyEQ(f) }
                    completion?()
                }
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
        guard let parsed = SonyCommand.parseEqualizer(f.payload, center: eqCenter) else { return }
        eqPreset = parsed.preset
        eqBands = parsed.bands
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
