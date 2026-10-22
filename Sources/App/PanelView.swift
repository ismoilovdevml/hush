import SwiftUI

private let cardRadius: CGFloat = 13

/// Control Center draws its groups as a translucent wash over the blurred panel, which means
/// the fill has to flip with the appearance: a pale grey card on a pale light panel is
/// invisible, and a dark card on a dark panel is the same problem upside down.
private extension ColorScheme {
    var cardFill: Color { self == .dark ? .white.opacity(0.09) : .black.opacity(0.05) }
    var tileFill: Color { self == .dark ? .white.opacity(0.08) : .black.opacity(0.045) }
    var hairline: Color { self == .dark ? .white.opacity(0.10) : .black.opacity(0.08) }
}

private struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        GlassBox(cornerRadius: cardRadius, fallbackFill: scheme.cardFill) {
            content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ANCTile: View {
    @Environment(\.colorScheme) private var scheme
    let mode: Headphones.ANC
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var label: some View {
        let content = VStack(spacing: 5) {
            Image(systemName: mode.symbol)
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(height: 19)
            Text(mode.short)
                .font(.system(size: 10.5, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        // The active mode is a solid accent fill, as Control Center does for an active
        // toggle: tinted glass is too faint to read as "selected", and in light appearance
        // it came out darker than its neighbours and looked disabled instead.
        //
        // Solid and glass must not be stacked. An opaque layer over a glass view leaves it
        // nothing to sample and it renders black around the edges.
        if selected {
            content
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor))
        } else {
            // A plain fill, not nested glass: glass inside glass composites into a flat dark
            // block, and Control Center does not nest it either.
            content
                .foregroundStyle(.primary)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(scheme.tileFill))
        }
    }
}

private struct SettingRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 19
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 42, height: 28)
                .contentShape(Rectangle())
                .foregroundStyle(.primary.opacity(hovering ? 1.0 : 0.85))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Scrolls its text when it does not fit, and sits still when it does.
private struct Marquee: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium)

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var shift: CGFloat = 0

    private var overflow: CGFloat { max(textWidth - boxWidth, 0) }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { inner in
                    Color.clear.onAppear { textWidth = inner.size.width }
                        .onChange(of: text) { _ in textWidth = inner.size.width }
                })
                .offset(x: shift)
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .onAppear { boxWidth = geo.size.width; restart() }
                .onChange(of: text) { _ in restart() }
                .onChange(of: overflow) { _ in restart() }
        }
        .frame(height: 15)
    }

    private func restart() {
        shift = 0
        guard overflow > 1 else { return }
        // out and back, with a pause at each end, rather than a loop that snaps
        withAnimation(.linear(duration: Double(overflow) / 22)
            .delay(1.6)
            .repeatForever(autoreverses: true)) {
            shift = -overflow
        }
    }
}

/// A slider drawn by hand.
///
/// The system one greys out whenever the app is not frontmost - taking a screenshot is
/// enough - so the fill stopped looking like a control. SwiftUI in this SDK exposes no way
/// to override that (there is no controlActiveState), and Control Center's own sliders keep
/// their fill regardless, so this draws its own.
private struct PanelSlider: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double?
    var onCommit: (() -> Void)?

    private let height: CGFloat = 6
    private let knob: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0
            let travel = geo.size.width - knob
            let x = knob / 2 + travel * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(scheme.hairline)
                    .frame(height: height)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(x, height), height: height)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: x - knob / 2)
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = range.lowerBound
                            + Double((drag.location.x - knob / 2) / max(travel, 1)) * span
                        var next = min(max(raw, range.lowerBound), range.upperBound)
                        if let step { next = (next / step).rounded() * step }
                        if next != value { value = next }
                    }
                    .onEnded { _ in onCommit?() }
            )
        }
        .frame(height: knob)
    }
}

/// One equalizer band: a vertical track with the knob travelling either side of flat.
private struct EQBand: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let value: Int
    let onChange: (Int) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let mid = h / 2
                let knobY = mid - CGFloat(value) / 6 * (mid - 5)
                ZStack {
                    Capsule().fill(scheme.hairline)
                        .frame(width: 3, height: h)
                        .position(x: w / 2, y: mid)
                    Capsule().fill(Color.accentColor)
                        .frame(width: 3, height: abs(knobY - mid))
                        .position(x: w / 2, y: (knobY + mid) / 2)
                    Circle().fill(.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .position(x: w / 2, y: knobY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let frac = max(-1, min(1, (mid - g.location.y) / (mid - 5)))
                            onChange(Int((frac * 6).rounded()))
                        }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 48)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

struct PanelView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var hp: Headphones
    @ObservedObject var np: NowPlaying

    var body: some View {
        VStack(spacing: 8) {
            header

            if hp.connected {
                ancCard
                mediaCard
                soundCard
            } else {
                // Nothing on the headphones can be read or changed while they are away, so
                // the panel drops those controls instead of showing a wall of dead ones.
                connectRow
                mediaCard
            }

            footer
        }
        .padding(10)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.18), value: hp.anc)
        .animation(.easeInOut(duration: 0.2), value: hp.connected)
        .animation(.easeInOut(duration: 0.18), value: hp.eqIsManual)
        .onAppear { hp.refresh() }
    }

    private var header: some View {
        GlassBox(cornerRadius: cardRadius, fallbackFill: scheme.cardFill) { headerBody }
    }

    private var headerBody: some View {
        HStack(spacing: 9) {
            Image(systemName: "headphones")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(scheme.tileFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(hp.name).font(.system(size: 12.5, weight: .semibold))
                Text(hp.connected ? "Connected · \(hp.codec)" : "Not connected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hp.connected, let battery = hp.battery {
                HStack(spacing: 4) {
                    Image(systemName: hp.charging ? "battery.100.bolt" : batterySymbol(battery))
                        .font(.system(size: 11))
                    Text("\(battery)%").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(scheme.tileFill))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var connectRow: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Bluetooth")!)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 11))
                Text("Connect in Bluetooth settings").font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background { GlassBox(cornerRadius: cardRadius, fallbackFill: scheme.cardFill) { Color.clear } }
    }

    private var ancCard: some View {
        Card {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Headphones.ANC.allCases) { mode in
                        ANCTile(mode: mode, selected: hp.anc == mode) { hp.setANC(mode) }
                    }
                }
                if hp.anc == .ambient {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.1").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            PanelSlider(value: $hp.ambientLevel, range: 0...20, step: 1,
                                        onCommit: { hp.pushANC() })
                            Image(systemName: "speaker.wave.3").font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        SettingRow(title: "Focus on Voice",
                                   isOn: Binding(get: { hp.focusOnVoice },
                                                 set: { hp.focusOnVoice = $0; hp.pushANC() }))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var mediaCard: some View {
        Card {
            VStack(spacing: 8) {
                if np.hasMedia { nowPlaying }
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    TransportButton(symbol: "backward.fill") { transport(.previous) }
                    TransportButton(symbol: np.playing ? "pause.fill" : "play.fill",
                                    size: 23) { transport(.toggle) }
                    TransportButton(symbol: "forward.fill") { transport(.next) }
                    Spacer(minLength: 0)
                }
                if !np.available && !hp.mediaKeysAllowed {
                    Button { MediaKeyAuth.openSettings() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            Text("Playback keys need Accessibility — grant access")
                                .font(.system(size: 10))
                            Image(systemName: "chevron.right").font(.system(size: 8))
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    PanelSlider(value: Binding(get: { hp.volume }, set: { hp.setVolume($0) }))
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Equalizer and DSEE are both "how it sounds", so they share one card rather than
    /// spending a card gap and a second set of insets on two single-line settings.
    private var soundCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    Text("Equalizer").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Menu {
                        ForEach(hp.eqPresets, id: \.code) { preset in
                            Button(preset.name) { hp.setEQPreset(preset.code) }
                        }
                    } label: {
                        Text(hp.eqPresets.first { $0.code == hp.eqPreset }?.name
                             ?? String(format: "0x%02x", hp.eqPreset))
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .frame(height: 22)

                if hp.eqIsManual {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(Array(hp.eqBands.enumerated()), id: \.offset) { index, value in
                            EQBand(label: hp.eqFrequencies[min(index, hp.eqFrequencies.count - 1)],
                                   value: value,
                                   onChange: { hp.eqBands[index] = $0 },
                                   onCommit: { hp.pushEQBands() })
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }

                Divider().padding(.vertical, 7)

                SettingRow(title: "DSEE Extreme",
                           subtitle: "Upscale compressed audio",
                           isOn: Binding(get: { hp.dsee }, set: { hp.setDSEE($0) }))
            }
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 7) {
            Button {
                np.openPlayer()
            } label: {
                HStack(spacing: 9) {
                    Group {
                        if let artwork = np.artwork {
                            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Rectangle().fill(scheme.tileFill)
                                Image(systemName: "music.note").font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Marquee(text: np.title)
                        if !np.artist.isEmpty {
                            Text(np.artist)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(np.bundleIdentifier == nil ? "" : "Open the player")

            if np.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = np.position(at: context.date)
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            let fraction = min(max(position / np.duration, 0), 1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(scheme.hairline).frame(height: 3)
                                Capsule().fill(Color.accentColor)
                                    .frame(width: geo.size.width * fraction, height: 3)
                            }
                            .frame(height: geo.size.height, alignment: .center)
                        }
                        .frame(height: 3)

                        HStack {
                            Text(clock(position))
                            Spacer()
                            Text("-" + clock(np.duration - position))
                        }
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var footer: some View {
        GlassBox(cornerRadius: cardRadius, fallbackFill: scheme.cardFill) { footerBody }
    }

    private var footerBody: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 6, height: 6)
                .foregroundStyle(hp.connected ? Color.green : Color.secondary)
            if hp.connected {
                Text("Firmware \(hp.firmware)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { hp.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Transport rides the adapter; synthetic media keys are only the fallback.
    private func transport(_ command: NowPlaying.Command) {
        if np.available {
            np.send(command)
        } else {
            switch command {
            case .previous: MediaKey.previous.post()
            case .next: MediaKey.next.post()
            default: MediaKey.playPause.post()
            }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case 0..<13: return "battery.0"
        case 13..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
