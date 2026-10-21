// NowPlaying — track metadata and transport, via the bundled mediaremote-adapter.
//
// macOS 15.4+ returns nothing from MediaRemote to unentitled processes (measured: the direct
// MRMediaRemoteGetNowPlayingInfo call gave nil for two minutes while Control Center showed the
// track). /usr/bin/perl is Apple-signed and entitled, so the adapter loads a small framework
// inside perl and relays the data as newline-delimited JSON.
// Bonus: transport commands go through the same path, so no Accessibility grant is needed.
import AppKit
import Combine

@MainActor
final class NowPlaying: ObservableObject {
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var playing = false
    @Published var hasMedia = false
    /// False when the adapter could not start — Apple may yet close this path.
    @Published var available = true

    private var task: Process?
    private var buffer = Data()

    private var script: String? { Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") }
    private var framework: String? {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter.framework").path
    }

    func start() {
        guard task == nil, let script, let framework,
              FileManager.default.fileExists(atPath: framework) else { available = false; return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--no-diff", "--debounce=400"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.task = nil
                self?.available = false
            }
        }
        do { try p.run(); task = p; available = true } catch { available = false }
    }

    func stop() {
        task?.terminate()
        task = nil
    }

    func send(_ command: Command) {
        guard let script, let framework else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "send", String(command.rawValue)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            apply(payload)
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }   // artwork is big; never let it run away
    }

    private func apply(_ p: [String: Any]) {
        guard let t = p["title"] as? String, !t.isEmpty else {
            if p.isEmpty { hasMedia = false; title = ""; artist = ""; artwork = nil; playing = false }
            return
        }
        hasMedia = true
        title = t
        artist = (p["artist"] as? String) ?? ""
        if let n = p["playing"] as? NSNumber { playing = n.boolValue }
        else if let r = p["playbackRate"] as? NSNumber { playing = r.doubleValue > 0 }
        if let b64 = p["artworkData"] as? String, let d = Data(base64Encoded: b64) {
            artwork = NSImage(data: d)
        } else if p["artworkData"] == nil, p["title"] != nil {
            // keep the previous artwork; a diff-free dump without artwork means none is offered
        }
    }
}
