import AppKit
import SwiftUI

/// A borderless panel under the menu bar item, used instead of NSPopover so we control the glass:
/// no arrow, a whiter tint (so text keeps full contrast), our own corner radius and shadow.
@MainActor
final class GlassPanel: NSPanel {
    static let radius: CGFloat = 26
    static let margin: CGFloat = 24  // transparent room around the sheet for its shadow

    private var monitors: [Any] = []
    private var spaceObserver: (any NSObjectProtocol)?
    private weak var anchor: NSStatusBarButton?
    private var idealSize: () -> NSSize = { .zero }
    var onClose: (() -> Void)?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        // Sized explicitly in show(); letting the window track SwiftUI's size continuously caused layout churn.
        let host = NSHostingController(rootView: GlassSheet(content: content()))
        host.sizingOptions = []
        contentViewController = host
        idealSize = { [unowned host] in host.sizeThatFits(in: NSSize(width: 10_000, height: 10_000)) }
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton) {
        anchor = button
        fitContent()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            animator().alphaValue = 1
        }
        installMonitors()
    }

    func dismiss() {
        removeMonitors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                self.onClose?()
            }
        }
    }

    /// One measurement and resize, e.g. when an energy row appears. Top stays pinned under the menu bar.
    func fitContent() {
        // Ask SwiftUI for its ideal size directly; with sizingOptions = [] the view's fittingSize is zero.
        setContentSize(idealSize())
        reposition()
    }

    private func reposition() {
        guard let button = anchor, let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        let anchorFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = frame.size
        let visible = screen.visibleFrame
        var x = anchorFrame.midX - size.width / 2
        x = min(max(x, visible.minX - Self.margin + 8), visible.maxX - size.width + Self.margin - 8)
        let top = anchorFrame.minY - 10 + Self.margin
        setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    // Close on a click anywhere else, Escape, or a switch to another Space.
    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.dismiss() }; return nil }
            return event
        }) { monitors.append(m) }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }
}

/// White-tinted Liquid Glass sheet with a soft shadow, matching the mockup.
private struct GlassSheet<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GlassPanel.radius, style: .continuous)
        content
            .glassEffect(.regular.tint(tint), in: shape)
            .background {
                shape.fill(.black.opacity(scheme == .dark ? 0.35 : 0.16))
                    .blur(radius: 18)
                    .offset(y: 10)
                    .padding(6)
            }
            .padding(GlassPanel.margin)
    }

    private var tint: Color {
        scheme == .dark ? Color(white: 0.12).opacity(0.55) : .white.opacity(0.62)
    }
}
