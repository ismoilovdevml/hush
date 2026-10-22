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
    @Published var duration: Double = 0
    /// Where playback stood at `elapsedAt`. Live position is derived from it, so the bar can
    /// move every second without asking the adapter again.
    @Published var elapsed: Double = 0
    @Published var elapsedAt = Date()
    /// The app doing the playing, so the panel can bring it forward.
    @Published var bundleIdentifier: String?

    /// Playback position now, carried forward from the last report while playing.
    func position(at moment: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let drift = playing ? moment.timeIntervalSince(elapsedAt) : 0
        return min(max(elapsed + drift, 0), duration)
    }

    /// Bring the player forward. In a browser that means the tab playing the track, not
    /// whatever tab happens to be in front — matched on the title, since neither Chrome nor
    /// Safari will say which tab is making the sound.
    func openPlayer() {
        guard let bundleIdentifier else { return }

        let browsers = [
            "com.google.Chrome": "Google Chrome",
            "com.brave.Browser": "Brave Browser",
            "com.microsoft.edgemac": "Microsoft Edge",
            "com.vivaldi.Vivaldi": "Vivaldi",
        ]
        if let app = browsers[bundleIdentifier], !title.isEmpty {
            focusChromiumTab(app: app)
        } else if bundleIdentifier == "com.apple.Safari", !title.isEmpty {
            focusSafariTab()
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// A tab title carries more than the track ("… - YouTube"), so match on a prefix of ours.
    private var titleNeedle: String {
        String(title.prefix(40))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func focusChromiumTab(app: String) {
        run(script: """
        tell application "\(app)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if title of t contains "\(titleNeedle)" then
                        set active tab index of w to i
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    private func focusSafariTab() {
        run(script: """
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    if name of t contains "\(titleNeedle)" then
                        set current tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    /// Fails quietly: this needs Automation permission, and the panel should not break
    /// because the user declined it. The app still comes forward either way.
    private func run(script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    /// False when the adapter could not start — Apple may yet close this path.
    @Published var available = true

    private var task: Process?
    private var buffer = Data()
    private static let timestamps: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The CLI runs outside the bundle, so fall back to an installed copy of the app.
    private static let resourceDirectory: String? = {
        var candidates: [String] = []
        if let own = Bundle.main.resourceURL?.path { candidates.append(own) }
        candidates += [
            "\(NSHomeDirectory())/Applications/Hush.app/Contents/Resources",
            "/Applications/Hush.app/Contents/Resources",
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: "\($0)/mediaremote-adapter.pl")
        }
    }()

    private var script: String? {
        Self.resourceDirectory.map { "\($0)/mediaremote-adapter.pl" }
    }
    private var framework: String? {
        Self.resourceDirectory.map { "\($0)/MediaRemoteAdapter.framework" }
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
            if p.isEmpty {
                hasMedia = false; title = ""; artist = ""; artwork = nil; playing = false
                duration = 0; elapsed = 0; bundleIdentifier = nil
            }
            return
        }
        hasMedia = true
        title = t
        if let d = p["duration"] as? NSNumber { duration = d.doubleValue }
        if let e = p["elapsedTime"] as? NSNumber {
            elapsed = e.doubleValue
            // The adapter stamps when the position was taken; without it the bar would jump
            // backwards every time a report arrives late.
            if let stamp = p["timestamp"] as? String, let at = Self.timestamps.date(from: stamp) {
                elapsedAt = at
            } else {
                elapsedAt = Date()
            }
        }
        if let bundle = p["bundleIdentifier"] as? String { bundleIdentifier = bundle }
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
