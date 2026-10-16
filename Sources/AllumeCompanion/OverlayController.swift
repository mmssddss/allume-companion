import AppKit
import SwiftUI

/// A panel that can take keyboard focus without activating this app (Spotlight-style),
/// so Allume stays the active app while the user interacts with the overlay.
final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return } // Esc
        super.keyDown(with: event)
    }
}

/// Owns the two overlay windows: a pill with the board title glued to the top of the Allume
/// window, and the command panel that drops down from it.
@MainActor
final class OverlayController {
    let state: AppState
    let pill: OverlayPanel
    let panel: OverlayPanel
    private var window: AllumeTracker.WindowInfo?

    static let pillSize = CGSize(width: 320, height: 30)
    static let panelSize = CGSize(width: 440, height: 400)
    static let pillTopInset: CGFloat = 52   // sits just under Allume's title bar / toolbar

    init(state: AppState, runner: CommandRunner) {
        self.state = state
        pill = Self.makePanel(size: Self.pillSize)
        pill.contentView = NSHostingView(rootView: PillView(state: state))
        panel = Self.makePanel(size: Self.panelSize)
        panel.contentView = NSHostingView(rootView: CommandPanelView(state: state, runner: runner))
        pill.onEscape = { [weak self] in self?.hidePanel() }
        panel.onEscape = { [weak self] in self?.hidePanel() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private static func makePanel(size: CGSize) -> OverlayPanel {
        let p = OverlayPanel(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = false
        return p
    }

    /// Called by the tracker whenever Allume's window moves/resizes/activates.
    func update(window: AllumeTracker.WindowInfo?) {
        self.window = window
        guard let window, window.isActive || panel.isKeyWindow else {
            if pill.isVisible { Log.info("pill hidden") }
            pill.orderOut(nil)
            panel.orderOut(nil)
            return
        }
        pill.setFrame(pillFrame(for: window.frame), display: true)
        if !pill.isVisible { pill.orderFront(nil); Log.info("pill shown at \(pill.frame)") }
        if panel.isVisible { panel.setFrame(panelFrame(for: window.frame), display: true) }
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    func showPanel() {
        guard let window else { return }
        panel.setFrame(panelFrame(for: window.frame), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hidePanel() {
        panel.orderOut(nil)
    }

    private func pillFrame(for w: CGRect) -> CGRect {
        let s = Self.pillSize
        return CGRect(x: w.midX - s.width / 2, y: w.maxY - Self.pillTopInset - s.height, width: s.width, height: s.height)
    }

    private func panelFrame(for w: CGRect) -> CGRect {
        let s = Self.panelSize
        let pillBottom = pillFrame(for: w).minY
        let height = min(s.height, max(200, pillBottom - w.minY - 16))
        return CGRect(x: w.midX - s.width / 2, y: pillBottom - 8 - height, width: s.width, height: height)
    }
}
