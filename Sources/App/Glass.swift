// Liquid Glass containers.
//
// SwiftUI in this SDK ships only the glass *button* styles — there is no `glassEffect`
// modifier — but AppKit's NSGlassEffectView is there from macOS 26.
//
// The content has to be the glass view's `contentView`, not a sibling drawn over it. The
// header says so plainly: "NSGlassEffectView only guarantees the contentView will be placed
// inside the glass effect; arbitrary subviews aren't guaranteed specific behavior with
// regard to z-order". Using the effect as a plain `.background` breaks that rule, and
// anything opaque on top — a filled tile, album artwork — tore black bars through the pill.
import SwiftUI

/// A named wrapper rather than AnyView. AnyView erases the view's identity, so SwiftUI
/// treats every update as a different view and resets the @State inside it — any animation
/// in a glass pill ran once and then froze.
struct SchemeWrapped<Content: View>: View {
    let scheme: ColorScheme
    let content: Content
    var body: some View { content.environment(\.colorScheme, scheme) }
}

struct GlassBox<Content: View>: NSViewRepresentable {
    var cornerRadius: CGFloat = 13
    var tint: NSColor?
    /// Drawn when the system is older than macOS 26 and there is no glass to be had.
    var fallbackFill: Color = .clear
    @ViewBuilder var content: () -> Content

    /// Control Center's pills are clear glass. In light appearance that is not safe: the pill
    /// shows whatever is behind the *window*, so a light panel over a dark window ends up with
    /// dark text on dark glass. The denser style keeps light appearance readable.
    @Environment(\.colorScheme) private var scheme

    final class Coordinator {
        var host: NSHostingView<SchemeWrapped<Content>>?
        /// A detached copy used only to measure. Resizing the live hosting view from inside
        /// sizeThatFits runs inside SwiftUI's own layout pass and aborts the process with an
        /// AttributeGraph precondition failure.
        var ruler: NSHostingView<SchemeWrapped<Content>>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The content lives in its own hosting view, which starts with a fresh SwiftUI
    /// environment — nothing is inherited from the view that placed this box. The appearance
    /// has to be handed over explicitly, or nested fills resolve against the wrong scheme and
    /// come out darker than the pill they sit on.
    private func wrapped() -> SchemeWrapped<Content> {
        SchemeWrapped(scheme: scheme, content: content())
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: wrapped())
        host.sizingOptions = [.intrinsicContentSize]
        context.coordinator.host = host

        guard #available(macOS 26.0, *) else {
            host.wantsLayer = true
            host.layer?.cornerRadius = cornerRadius
            host.layer?.cornerCurve = .continuous
            host.layer?.backgroundColor = NSColor(fallbackFill).cgColor
            return host
        }

        let glass = NSGlassEffectView()
        glass.contentView = host
        apply(to: glass)
        return glass
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host?.rootView = wrapped()
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            apply(to: glass)
        } else {
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.backgroundColor = NSColor(fallbackFill).cgColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let ruler: NSHostingView<SchemeWrapped<Content>>
        if let existing = context.coordinator.ruler {
            ruler = existing
            ruler.rootView = wrapped()
        } else {
            ruler = NSHostingView(rootView: wrapped())
            ruler.sizingOptions = [.intrinsicContentSize]
            context.coordinator.ruler = ruler
        }
        let width = proposal.width ?? ruler.intrinsicContentSize.width
        ruler.setFrameSize(NSSize(width: width, height: 0))
        return CGSize(width: width, height: ruler.fittingSize.height)
    }

    @available(macOS 26.0, *)
    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.tintColor = tint
        // Regular, not clear, in both appearances. Clear glass carries almost no body: the
        // page behind read straight through the pills, logo and all. Control Center takes the
        // background's colour but hides its detail, which is what regular does — the earlier
        // judgement that it was "too solid" came from comparing a light-appearance panel
        // against a dark-appearance Control Center.
        view.style = .regular
    }
}

var liquidGlassAvailable: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}


/// Watches for the system switching between light and dark.
///
/// Each glass pill keeps its own hosting view, and SwiftUI does not necessarily re-evaluate
/// every one of them when the appearance changes — so some pills kept the old look while
/// their neighbours switched, leaving a dark footer under a light panel. Bumping this tick
/// changes the panel's identity and rebuilds all of them together.
@MainActor
final class AppearanceWatcher: ObservableObject {
    @Published private(set) var tick = 0

    init() {
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick += 1 }
        }
    }
}
