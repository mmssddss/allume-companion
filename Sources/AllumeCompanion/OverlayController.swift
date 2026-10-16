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

/// Owns the command panel: hidden by default, dropped down from the top of the Allume window
/// by ⌘K, dismissed by Esc, ⌘K again, clicking back into Allume, or Allume leaving the front.
@MainActor
final class OverlayController {
    let state: AppState
    let panel: OverlayPanel
    private var window: AllumeTracker.WindowInfo?

    static let panelSize = CGSize(width: 560, height: 400)
    /// Height the view last asked for (search row + visible rows + footer).
    private var contentHeight: CGFloat = panelSize.height
    static let topInset: CGFloat = 52   // just under Allume's title bar / toolbar

    init(state: AppState, runner: CommandRunner) {
        self.state = state
        panel = Self.makePanel(size: Self.panelSize)
        panel.contentView = NSHostingView(rootView: CommandPanelView(state: state, runner: runner))
        panel.onEscape = { [weak self] in self?.hidePanel() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
        NotificationCenter.default.addObserver(forName: .panelHeight, object: nil, queue: .main) { [weak self] note in
            guard let h = note.object as? CGFloat else { return }
            Task { @MainActor in
                guard let self, self.contentHeight != h else { return }
                self.contentHeight = h
                if self.panel.isVisible, let w = self.window { self.panel.setFrame(self.panelFrame(for: w.frame), display: true) }
                Log.info("panel height → \(h), frame \(self.panel.frame)")
            }
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

    var isPanelVisible: Bool { panel.isVisible }

    /// Called by the tracker whenever Allume's window moves/resizes/activates.
    func update(window: AllumeTracker.WindowInfo?) {
        self.window = window
        guard let window, window.isActive || panel.isKeyWindow else {
            hidePanel()
            return
        }
        if panel.isVisible { panel.setFrame(panelFrame(for: window.frame), display: true) }
    }

    func showPanel() {
        guard let window else { return }
        panel.setFrame(panelFrame(for: window.frame), display: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .panelShown, object: nil)
        Log.info("panel shown at \(panel.frame)")
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        Log.info("panel hidden")
    }

    /// Anchored at the top (just under Allume's title bar), so growing or shrinking only moves
    /// the bottom edge; never taller than the space left in the Allume window.
    private func panelFrame(for w: CGRect) -> CGRect {
        let s = Self.panelSize
        let top = w.maxY - Self.topInset
        let height = min(contentHeight, max(120, top - w.minY - 16))
        return CGRect(x: w.midX - s.width / 2, y: top - height, width: s.width, height: height)
    }
}
