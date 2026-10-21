import SwiftUI

private let cardRadius: CGFloat = 14

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }
}

private struct ANCTile: View {
    let mode: Headphones.ANC
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 22)
                Text(mode.short)
                    .font(.system(size: 10.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 20
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(.primary.opacity(hovering ? 1.0 : 0.85))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One equalizer band: a vertical track with the knob travelling either side of flat.
private struct EQBand: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let mid = h / 2
                let knobY = mid - CGFloat(value) / 6 * (mid - 5)
                ZStack {
                    Capsule().fill(.quaternary)
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
            .frame(height: 58)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

struct PanelView: View {
    @ObservedObject var hp: Headphones
    @ObservedObject var np: NowPlaying

    var body: some View {
        VStack(spacing: 10) {
            header

            Card {
                VStack(spacing: 10) {
                    HStack(spacing: 7) {
                        ForEach(Headphones.ANC.allCases) { mode in
                            ANCTile(mode: mode, selected: hp.anc == mode) { hp.setANC(mode) }
                        }
                    }
                    if hp.anc == .ambient {
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.1").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Slider(value: $hp.ambientLevel, in: 0...20, step: 1) { editing in
                                    if !editing { hp.pushANC() }
                                }
                                Image(systemName: "speaker.wave.3").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Toggle(isOn: Binding(get: { hp.focusOnVoice },
                                                 set: { hp.focusOnVoice = $0; hp.pushANC() })) {
                                Text("Focus on Voice").font(.system(size: 11))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            Card {
                VStack(spacing: 10) {
                    if np.hasMedia { nowPlaying }
                    HStack(spacing: 18) {
                        Spacer(minLength: 0)
                        TransportButton(symbol: "backward.fill") { transport(.previous) }
                        TransportButton(symbol: np.playing ? "pause.fill" : "play.fill",
                                        size: 25) { transport(.toggle) }
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
                        Slider(value: Binding(get: { hp.volume }, set: { hp.setVolume($0) }), in: 0...100)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }

            Card {
                VStack(spacing: 8) {
                    HStack {
                        Text("Equalizer").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Menu {
                            ForEach(Headphones.eqPresets, id: \.code) { preset in
                                Button(preset.name) { hp.setEQPreset(preset.code) }
                            }
                        } label: {
                            Text(Headphones.eqPresets.first { $0.code == hp.eqPreset }?.name
                                 ?? String(format: "0x%02x", hp.eqPreset))
                                .font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    if hp.eqIsManual {
                        HStack(alignment: .bottom, spacing: 1) {
                            ForEach(Array(hp.eqBands.enumerated()), id: \.offset) { idx, value in
                                EQBand(label: Headphones.eqFrequencies[min(idx, 9)],
                                       value: value,
                                       onChange: { hp.eqBands[idx] = $0 },
                                       onCommit: { hp.pushEQBands() })
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }

            Card {
                Toggle(isOn: Binding(get: { hp.dsee }, set: { hp.setDSEE($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DSEE Extreme").font(.system(size: 12, weight: .medium))
                        Text("Upscale compressed audio").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            footer
        }
        .padding(12)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.18), value: hp.anc)
        .animation(.easeInOut(duration: 0.18), value: hp.eqIsManual)
        .onAppear { hp.refresh() }
    }

    /// Transport rides the adapter; synthetic media keys are only the fallback.
    private func transport(_ c: NowPlaying.Command) {
        if np.available {
            np.send(c)
        } else {
            switch c {
            case .previous: MediaKey.previous.post()
            case .next: MediaKey.next.post()
            default: MediaKey.playPause.post()
            }
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 9) {
            Group {
                if let art = np.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(np.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !np.artist.isEmpty {
                    Text(np.artist).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.quaternary.opacity(0.5)))
            VStack(alignment: .leading, spacing: 1) {
                Text(hp.name).font(.system(size: 13, weight: .semibold))
                Text(hp.connected ? "Connected · \(hp.codec)" : "Not connected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let b = hp.battery {
                HStack(spacing: 4) {
                    Image(systemName: hp.charging ? "battery.100.bolt" : batterySymbol(b))
                        .font(.system(size: 11))
                    Text("\(b)%").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
            }
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 6, height: 6)
                .foregroundStyle(hp.connected ? Color.green : Color.secondary)
            Text(hp.connected ? "Firmware \(hp.firmware)" : "Headphones offline")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button { hp.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case 0..<13: return "battery.0"
        case 13..<38: return "battery.25"
        case 38..<63: return "battery.50"
        case 63..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
