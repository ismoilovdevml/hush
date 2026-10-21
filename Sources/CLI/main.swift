// hush — command line control for the same headphones the app drives.
//
// It prefers a running Hush.app over the control socket, because the headphones accept only
// one RFCOMM connection. With no app running it opens channel 9 itself and runs the identical
// ControlService, so the behaviour does not change with how you invoke it.
import Foundation
import AppKit

let usage = """
hush — control Sony WH-1000XM6 headphones from the terminal

  hush                            show everything
  hush status [--json]

  hush anc off|nc|ambient [--level 0-20] [--focus|--no-focus]
  hush eq                         show the current curve
  hush eq <preset>                off, heavy, clear, hard, soft, gaming, manual, user1, user2
  hush eq set <10 values>         each between -6 and +6, e.g. hush eq set 4 3 1 0 0 0 0 1 3 4
  hush dsee on|off

  hush play|pause|toggle|next|prev
  hush volume [0-100]

  hush raw "<hex>" [--type 0c] [--expect 67]
                                  send one frame and print the reply.
                                  The opcode allow list still applies: factory reset,
                                  reboot, power off and firmware transfer are refused.

  --json                          machine readable output, for any command
"""

var args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--json")
args.removeAll { $0 == "--json" }

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

// ---- build the request -------------------------------------------------------------------

let level = flagValue("--level").flatMap { Int($0) }
let dataType = flagValue("--type").flatMap { UInt8($0, radix: 16) }
let expect = flagValue("--expect").flatMap { UInt8($0, radix: 16) }
let focusOn = takeFlag("--focus")
let focusOff = takeFlag("--no-focus")

let verb = args.first ?? "status"
var request: [String: Any]

switch verb {
case "status", "":
    request = ["cmd": "status"]

case "anc":
    guard args.count > 1 else { print("anc: off, nc or ambient"); exit(2) }
    request = ["cmd": "anc", "mode": args[1]]
    if let level { request["level"] = level }
    if focusOn { request["focus"] = true }
    if focusOff { request["focus"] = false }

case "eq":
    if args.count > 1, args[1] == "set" {
        let values = args.dropFirst(2).compactMap { Int($0) }
        guard values.count == 10 else { print("eq set: expected 10 values between -6 and +6"); exit(2) }
        request = ["cmd": "eq", "bands": values]
    } else if args.count > 1 {
        request = ["cmd": "eq", "preset": args[1]]
    } else {
        request = ["cmd": "eq"]
    }

case "dsee":
    guard args.count > 1, ["on", "off"].contains(args[1]) else { print("dsee: on or off"); exit(2) }
    request = ["cmd": "dsee", "on": args[1] == "on"]

case "volume":
    request = ["cmd": "volume"]
    if args.count > 1, let value = Int(args[1]) { request["value"] = value }

case "play", "pause", "toggle", "next", "prev", "previous":
    request = ["cmd": "media", "action": verb]

case "raw":
    guard args.count > 1 else { print("raw: needs a payload, e.g. hush raw \"66 19\""); exit(2) }
    request = ["cmd": "raw", "payload": args[1]]
    if let dataType { request["dataType"] = Int(dataType) }
    if let expect { request["expect"] = Int(expect) }

case "help", "--help", "-h":
    print(usage); exit(0)

default:
    print("unknown command '\(verb)'\n"); print(usage); exit(2)
}

// ---- run it, through the app when one is listening ----------------------------------------

func report(_ response: [String: Any]) -> Never {
    if wantsJSON {
        let data = try? JSONSerialization.data(withJSONObject: response,
                                               options: [.prettyPrinted, .sortedKeys])
        print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    } else {
        printHuman(response)
    }
    exit(response["ok"] as? Bool == true ? 0 : 1)
}

func printHuman(_ r: [String: Any]) {
    if let error = r["error"] as? String { print("error: \(error)"); return }
    if let reply = r["reply"] as? String { print(reply); return }
    if let action = r["action"] as? String { print(action); return }
    guard r["connected"] != nil else {
        if let volume = r["volume"] as? Int { print("volume \(volume)%") }
        return
    }

    let name = r["name"] as? String ?? "headphones"
    if r["connected"] as? Bool == true {
        var head = name
        if let battery = r["battery"] as? Int {
            head += "  \(battery)%" + (r["charging"] as? Bool == true ? " charging" : "")
        }
        if let codec = r["codec"] as? String { head += "  \(codec)" }
        if let firmware = r["firmware"] as? String { head += "  fw \(firmware)" }
        print(head)
    } else {
        print("\(name) — not connected")
        return
    }

    let ancNames = ["off": "Off", "nc": "Noise Cancelling", "ambient": "Ambient Sound"]
    var anc = "  anc       " + (ancNames[r["anc"] as? String ?? ""] ?? "?")
    if r["anc"] as? String == "ambient" {
        anc += "  level \(r["ambientLevel"] as? Int ?? 0)"
        if r["focusOnVoice"] as? Bool == true { anc += "  focus on voice" }
    }
    print(anc)
    print("  dsee      " + (r["dsee"] as? Bool == true ? "on" : "off"))
    print("  volume    \(r["volume"] as? Int ?? 0)%")

    if let bands = r["eqBands"] as? [Int], let freqs = r["eqFrequencies"] as? [String] {
        print("  eq        \(r["eqPreset"] as? String ?? "?")")
        for (i, value) in bands.enumerated() where i < freqs.count {
            let bar = value >= 0 ? String(repeating: "#", count: value)
                                 : String(repeating: "-", count: -value)
            let label = freqs[i].padding(toLength: 4, withPad: " ", startingAt: 0)
            print(String(format: "    %@ %+3d  %@", label, value, bar))
        }
    }
    if let playing = r["nowPlaying"] as? [String: Any] {
        let mark = playing["playing"] as? Bool == true ? "▶" : "❚❚"
        print("  playing   \(mark) \(playing["title"] as? String ?? "")")
    }
}

if let response = ControlSocket.send(request) {
    report(response)
}

// No app listening — drive the headphones directly.
MainActor.assumeIsolated {
    guard let found = findHeadset() else {
        report(["ok": false, "error": "no paired Sony headphones found"])
    }

    NSApplication.shared.setActivationPolicy(.prohibited)

    let headphones = Headphones(address: found.address)
    headphones.name = found.name
    let nowPlaying = NowPlaying()
    let service = ControlService(headphones: headphones, nowPlaying: nowPlaying)

    var answer: [String: Any]?
    service.execute(request) { answer = $0 }

    let deadline = Date().addingTimeInterval(8)
    while answer == nil, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    report(answer ?? ["ok": false, "error": "the headphones did not answer"])
}
