// Executes one control request. The app serves these over the control socket; the CLI runs
// the very same code directly when no app is running, so both paths behave identically.
import Foundation

@MainActor
final class ControlService {
    let headphones: Headphones
    let nowPlaying: NowPlaying

    init(headphones: Headphones, nowPlaying: NowPlaying) {
        self.headphones = headphones
        self.nowPlaying = nowPlaying
    }

    private static let ancByName: [String: Headphones.ANC] = [
        "off": .off, "nc": .noiseCancelling, "noise": .noiseCancelling,
        "ambient": .ambient, "transparency": .ambient,
    ]

    private func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

    /// Answer a write with freshly read state. A one-shot CLI process has read nothing yet,
    /// so replying from cached values would print defaults that are simply untrue.
    private func replyWithState(_ reply: @escaping ([String: Any]) -> Void) {
        headphones.refresh { [weak self] in
            guard let self else { return }
            reply(self.state())
        }
    }

    func execute(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let command = (request["cmd"] as? String) ?? ""

        switch command {
        case "status":
            headphones.refresh { [weak self] in
                guard let self else { return }
                reply(self.state())
            }

        case "anc":
            guard let name = request["mode"] as? String,
                  let mode = Self.ancByName[name.lowercased()] else {
                return reply(fail("anc: mode must be off, nc or ambient"))
            }
            if let level = request["level"] as? Int {
                headphones.ambientLevel = Double(min(max(level, 0), 20))
            }
            if let focus = request["focus"] as? Bool { headphones.focusOnVoice = focus }
            headphones.setANC(mode) { [weak self] in
                self?.replyWithState(reply)
            }

        case "eq":
            if let bands = request["bands"] as? [Int] {
                guard bands.count == headphones.eqBands.count else {
                    return reply(fail("eq: expected \(headphones.eqBands.count) bands"))
                }
                guard bands.allSatisfy({ $0 >= -6 && $0 <= 6 }) else {
                    return reply(fail("eq: every band must be between -6 and +6"))
                }
                headphones.eqBands = bands
                headphones.pushEQBands { [weak self] in
                    self?.replyWithState(reply)
                }
            } else if let preset = request["preset"] as? String {
                guard let match = Headphones.allPresets.first(where: {
                    $0.name.lowercased().replacingOccurrences(of: " ", with: "") == preset.lowercased()
                }) else {
                    let names = Headphones.allPresets.map { $0.name }.joined(separator: ", ")
                    return reply(fail("eq: unknown preset '\(preset)' — try one of: \(names)"))
                }
                headphones.setEQPreset(match.code) { [weak self] in
                    self?.replyWithState(reply)
                }
            } else {
                replyWithState(reply)
            }

        case "dsee":
            guard let on = request["on"] as? Bool else { return reply(fail("dsee: on must be true or false")) }
            headphones.setDSEE(on) { [weak self] in
                self?.replyWithState(reply)
            }

        case "volume":
            if let value = request["value"] as? Int { headphones.setVolume(Double(value)) }
            reply(["ok": true, "volume": Int(SystemVolume.get().rounded())])

        case "media":
            let actions: [String: NowPlaying.Command] = [
                "play": .play, "pause": .pause, "toggle": .toggle,
                "next": .next, "prev": .previous, "previous": .previous,
            ]
            guard let name = request["action"] as? String, let action = actions[name.lowercased()] else {
                return reply(fail("media: action must be play, pause, toggle, next or prev"))
            }
            nowPlaying.send(action)
            reply(["ok": true, "action": name])

        case "raw":
            guard let hex = request["payload"] as? String else {
                return reply(fail("raw: payload required, e.g. \"66 19\""))
            }
            let bytes = hex.split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { UInt8($0, radix: 16) }
            guard let opcode = bytes.first else { return reply(fail("raw: payload is empty")) }
            let dataType = UInt8((request["dataType"] as? Int) ?? 0x0C)
            let expect = UInt8((request["expect"] as? Int) ?? Int(opcode | 0x01))
            headphones.sendRaw(dataType: dataType, payload: bytes, expect: expect) { payload in
                guard let payload else {
                    return reply(["ok": false, "error": "no reply (opcode refused, or the headphones stayed quiet)"])
                }
                reply(["ok": true, "reply": payload.map { String(format: "%02x", $0) }.joined(separator: " ")])
            }

        default:
            reply(fail("unknown command '\(command)'"))
        }
    }

    func state() -> [String: Any] {
        let hp = headphones
        var out: [String: Any] = [
            "ok": true,
            "connected": hp.connected,
            "name": hp.name,
            "codec": hp.codec,
            "firmware": hp.firmware,
            "anc": hp.anc == .off ? "off" : (hp.anc == .ambient ? "ambient" : "nc"),
            "ambientLevel": Int(hp.ambientLevel),
            "focusOnVoice": hp.focusOnVoice,
            "dsee": hp.dsee,
            "eqPreset": Headphones.allPresets.first { $0.code == hp.eqPreset }?.name ?? "unknown",
            "eqBands": hp.eqBands,
            "eqFrequencies": hp.eqFrequencies,
            "volume": Int(SystemVolume.get().rounded()),
        ]
        if let battery = hp.battery {
            out["battery"] = battery
            out["charging"] = hp.charging
        }
        if nowPlaying.hasMedia {
            out["nowPlaying"] = [
                "title": nowPlaying.title,
                "artist": nowPlaying.artist,
                "playing": nowPlaying.playing,
            ]
        }
        return out
    }
}
