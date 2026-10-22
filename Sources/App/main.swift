import AppKit
import SwiftUI
import IOBluetooth

/// Borderless panel that sits strictly inside the screen's visibleFrame, so it can never
/// slide under the menu bar or the camera notch the way an NSPopover does.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // Control Center keeps white labels whatever the system appearance, because clear
        // glass shows whatever is behind the window - a light-appearance panel over a dark
        // window leaves dark text on dark glass. Pin the panel to the dark appearance for
        // the same reason, unless HUSH_APPEARANCE asks otherwise.
        if ProcessInfo.processInfo.environment["HUSH_APPEARANCE"] == nil {
            appearance = NSAppearance(named: .darkAqua)
        }
        hasShadow = true
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Liquid Glass elements sample the desktop directly, so the window paints nothing
        // of its own. Before macOS 26 there is no glass, so the old blurred panel stands in.
        let container: NSView
        if liquidGlassAvailable {
            container = NSView()
            container.wantsLayer = true
            hasShadow = false
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 16
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            container = blur
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = container
    }

    /// Place the panel under the menu bar, centred on `anchor`, fully inside visibleFrame.
    func position(under anchor: NSRect, on screen: NSScreen) {
        let safe = screen.visibleFrame          // already excludes menu bar + notch band
        let size = contentView?.fittingSize ?? frame.size
        let w = max(size.width, 320), h = size.height
        let gap: CGFloat = 8
        var x = anchor.midX - w / 2
        x = min(max(x, safe.minX + gap), safe.maxX - w - gap)
        let y = safe.maxY - h - gap
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    private var hp: Headphones!
    private var np: NowPlaying!
    private var outsideClick: Any?
    private var escKey: Any?
    private var pinned = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let found = findHeadset()
        hp = Headphones(address: found?.address ?? "58-18-62-38-6F-EC")
        if let n = found?.name { hp.name = n }
        pinned = ProcessInfo.processInfo.environment["HUSH_PIN"] == "1"
        // HUSH_APPEARANCE=light|dark forces one appearance, for checking both without
        // switching the whole system.
        switch ProcessInfo.processInfo.environment["HUSH_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Hush")
            b.image?.isTemplate = true
            b.action = #selector(toggle(_:))
            b.target = self
        }

        np = NowPlaying()
        np.start()
        // Serve the CLI: it cannot open channel 9 itself while this app holds it.
        let service = ControlService(headphones: hp, nowPlaying: np)
        ControlSocket.serve { request, respond in
            MainActor.assumeIsolated { service.execute(request, reply: respond) }
        }

        let host = NSHostingView(rootView: PanelView(hp: hp, np: np))
        panel = PanelWindow(content: host)

        // Closing on focus loss is the reliable path: a global mouse monitor alone needs
        // Accessibility trust and silently does nothing without it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        if pinned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.show() } }
    }

    @objc private func toggle(_ sender: Any?) {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        hp.refresh()
        guard let b = statusItem.button, let w = b.window,
              let screen = w.screen ?? NSScreen.main else { return }
        panel.layoutIfNeeded()
        panel.position(under: w.frame, on: screen)
        panel.alphaValue = 0
        if !pinned { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)

        guard !pinned else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        escKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }   // esc
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func hide() {
        guard panel?.isVisible == true else { return }
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        if let m = escKey { NSEvent.removeMonitor(m); escKey = nil }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
