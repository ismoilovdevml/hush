// SonyLink — one long-lived RFCOMM channel to a Sony MDR v2 headset.
// Framing, escaping, checksum, auto-ACK and sequence handling, plus a hard opcode guard.
import Foundation
import IOBluetooth

enum Sony {
    static let start: UInt8 = 0x3E, end: UInt8 = 0x3C, esc: UInt8 = 0x3D
    static let ack: UInt8 = 0x01, cmd1: UInt8 = 0x0C, cmd2: UInt8 = 0x0E

    /// Opcodes this app is allowed to emit. Anything else is refused before it reaches the air.
    /// Deliberately excluded, because on protocol v2 they are destructive or unverified:
    ///   0xF8 FACTORY_RESET_SET · 0x98 SYSTEM_CONTROL_SET (reboot) · 0x24 POWER_SET
    ///   0x2D LARGE_DATA_COMMON (firmware) · 0xC4 JSON_GET · 0x58 EQUALIZER_SET (encoding unverified)
    static let allowed: Set<UInt8> = [0x00, 0x04, 0x12, 0x22, 0x56, 0x66, 0x68, 0xE6, 0xE8, 0xF6]
    static let forbidden: Set<UInt8> = [0xF8, 0x98, 0x24, 0x2D, 0xC4, 0x58]
}

struct SonyFrame {
    let dataType: UInt8, seq: UInt8, payload: [UInt8]
    var opcode: UInt8 { payload.first ?? 0xFF }
}

final class SonyLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum State: Equatable { case offline, connecting, online }

    private(set) var state: State = .offline { didSet { if state != oldValue { onState?(state) } } }
    var onState: ((State) -> Void)?
    var onNotify: ((SonyFrame) -> Void)?

    private let address: String
    private let channelID: UInt8
    private var channel: IOBluetoothRFCOMMChannel?
    private var rx: [UInt8] = []
    private var txSeq: UInt8 = 0

    private struct Job {
        let dataType: UInt8, payload: [UInt8], expect: UInt8
        let timeout: TimeInterval
        let done: (SonyFrame?) -> Void
    }
    /// The headset is strictly request/response: the sequence bit flips per exchange, so firing
    /// several commands at once makes all but the first vanish. One job in flight, always.
    private var queue: [Job] = []
    private var inFlight: Job?
    private var deadline: Date?
    private var reaper: Timer?

    init(address: String, channelID: UInt8 = 9) {
        self.address = address
        self.channelID = channelID
        super.init()
        reaper = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reap() }
    }

    // MARK: connection

    @discardableResult
    func connect() -> Bool {
        guard state != .online else { return true }
        state = .connecting
        guard let dev = IOBluetoothDevice(addressString: address), dev.isConnected() else {
            state = .offline; return false
        }
        var c: IOBluetoothRFCOMMChannel?
        let rc = dev.openRFCOMMChannelSync(&c, withChannelID: BluetoothRFCOMMChannelID(channelID), delegate: self)
        guard rc == kIOReturnSuccess, let opened = c else { state = .offline; return false }
        channel = opened
        rx.removeAll(); txSeq = 0
        state = .online
        return true
    }

    func disconnect() {
        channel?.close(); channel = nil; state = .offline
    }

    // MARK: sending

    /// Queue a request; `done` gets the first reply whose opcode matches `expect`, or nil on timeout.
    func request(_ dataType: UInt8, _ payload: [UInt8], expect: UInt8,
                 timeout: TimeInterval = 2.5, done: @escaping (SonyFrame?) -> Void) {
        guard let op = payload.first else { done(nil); return }
        guard !Sony.forbidden.contains(op), Sony.allowed.contains(op) else {
            NSLog("Hush: REFUSED opcode 0x%02x — not on the whitelist", op)
            done(nil); return
        }
        queue.append(Job(dataType: dataType, payload: payload, expect: expect, timeout: timeout, done: done))
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        guard state == .online || connect() else {
            let dropped = queue; queue.removeAll()
            dropped.forEach { $0.done(nil) }
            return
        }
        let job = queue.removeFirst()
        inFlight = job
        deadline = Date().addingTimeInterval(job.timeout)
        write(encode(job.dataType, txSeq, job.payload))
    }

    private func finish(_ frame: SonyFrame?) {
        guard let job = inFlight else { return }
        inFlight = nil
        deadline = nil
        job.done(frame)
        pump()
    }

    private func encode(_ dt: UInt8, _ seq: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        var body: [UInt8] = [dt, seq, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
        body += payload
        body.append(UInt8(body.reduce(0) { $0 + Int($1) } & 0xff))
        var out: [UInt8] = [Sony.start]
        for b in body {
            if b == Sony.start || b == Sony.end || b == Sony.esc { out += [Sony.esc, b & ~0x10] } else { out.append(b) }
        }
        out.append(Sony.end)
        return out
    }

    private func write(_ bytes: [UInt8]) {
        var m = bytes
        _ = m.withUnsafeMutableBufferPointer { bp in channel?.writeSync(bp.baseAddress, length: UInt16(bp.count)) }
    }

    // MARK: receiving

    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length: Int) {
        rx += UnsafeRawBufferPointer(start: p, count: length).map { $0 }
        drain()
    }

    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        channel = nil
        state = .offline
        let dropped = queue; queue.removeAll()
        finish(nil)
        dropped.forEach { $0.done(nil) }
    }

    private func drain() {
        while let s = rx.firstIndex(of: Sony.start) {
            var body: [UInt8] = [], i = s + 1, closed = false
            while i < rx.count {
                if rx[i] == Sony.end { closed = true; break }
                if rx[i] == Sony.esc { i += 1; if i < rx.count { body.append(rx[i] | 0x10) } } else { body.append(rx[i]) }
                i += 1
            }
            if !closed { if s > 0 { rx.removeSubrange(0..<s) }; return }
            rx.removeSubrange(0...i)
            guard body.count >= 7 else { continue }
            let checksum = UInt8(body[0..<(body.count - 1)].reduce(0) { $0 + Int($1) } & 0xff)
            guard checksum == body[body.count - 1] else { continue }
            let len = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
            guard len == body.count - 7 else { continue }
            let payload = Array(body[6..<(6 + len)])
            let frame = SonyFrame(dataType: body[0], seq: body[1], payload: payload)

            if frame.dataType == Sony.ack {
                txSeq = frame.seq                       // our next request rides the flipped sequence
                continue
            }
            write(encode(Sony.ack, 1 &- frame.seq, []))  // unacked frames get retransmitted ~5x
            if let job = inFlight, job.expect == frame.opcode {
                finish(frame)
            } else {
                onNotify?(frame)
            }
        }
    }

    private func reap() {
        if let d = deadline, d < Date() { finish(nil) } else { pump() }
    }
}
