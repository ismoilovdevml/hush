// Liquid Glass backgrounds.
//
// SwiftUI in this SDK ships only the glass *button* styles — there is no `glassEffect`
// modifier — but AppKit's NSGlassEffectView is there from macOS 26, so the real effect is
// reachable by wrapping it. On anything older this falls back to the previous flat fill, so
// the panel still looks deliberate rather than broken.
import SwiftUI

struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 13
    var tint: NSColor?
    /// Control Center's own pills are `.clear`: the desktop reads straight through them and
    /// only a rim light and a faint tint remain. `.regular` is far more opaque and reads as a
    /// solid block next to the real thing.
    var clear = true

    func makeNSView(context: Context) -> NSView {
        guard #available(macOS 26.0, *) else { return NSView() }
        let view = NSGlassEffectView()
        // Without a contentView the effect renders inconsistently between instances;
        // an empty one is enough to make every pill sample the same way.
        view.contentView = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard #available(macOS 26.0, *), let view = nsView as? NSGlassEffectView else { return }
        apply(to: view)
    }

    @available(macOS 26.0, *)
    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.tintColor = tint
        view.style = clear ? .clear : .regular
    }
}

extension View {
    /// Glass where the system can draw it, the old translucent fill where it cannot.
    @ViewBuilder
    func glass(cornerRadius: CGFloat = 13, tint: NSColor? = nil, clear: Bool = true,
               fallback: Color) -> some View {
        if #available(macOS 26.0, *) {
            background(GlassBackground(cornerRadius: cornerRadius, tint: tint, clear: clear))
        } else {
            background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

var liquidGlassAvailable: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}
