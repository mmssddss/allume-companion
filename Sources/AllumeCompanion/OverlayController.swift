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
    static let topInset: CGFloat = 52   // never higher than this below Allume's top edge
    /// Height the panel had when it was last shown: it is centered in the Allume window at that
    /// height, and later growth or shrinking only moves the bottom edge, so the search row
    /// stays where the user's eyes already are.
    private var anchorHeight: CGFloat = panelSize.height

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
                if self.panel.isVisible, let w = self.window {
                    // Same duration and curve as the list inside (CommandPanelView.resizeAnimation),
                    // so the bottom edge and the rows move together instead of jumping.
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = PanelMetrics.resizeDuration
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.panel.animator().setFrame(self.panelFrame(for: w.frame), display: true)
                    }
                }
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

    /// Orders the panel in once, fully transparent and off-screen, and out again on the next
    /// run-loop turn: SwiftUI's first layout and the window server's first composite then happen
    /// at launch instead of on the first ⌘K (measured ~50 ms for the first show vs ~10 ms after).
    func prewarm() {
        panel.alphaValue = 0
        panel.setFrame(CGRect(x: -4000, y: -4000, width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    /// Called by the tracker whenever Allume's window moves/resizes/activates. A hidden panel
    /// follows the window too (laid out now, off-screen), so the next `showPanel` is a bare
    /// `orderFront` even right after launch or after Allume was resized.
    func update(window: AllumeTracker.WindowInfo?) {
        self.window = window
        guard let window, window.isActive || panel.isKeyWindow else {
            hidePanel()
            if let w = window { place(for: w.frame) }
            return
        }
        if panel.isVisible { panel.setFrame(panelFrame(for: window.frame), display: true) } else { place(for: window.frame) }
    }

    /// Moves the hidden panel to where it would open; redraws only when the size changed.
    private func place(for windowFrame: CGRect) {
        let frame = panelFrame(for: windowFrame)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: panel.frame.size != frame.size)
    }

    /// `expectedRows` sizes the first frame right away, so the panel does not pop up at the
    /// previous height and then jump once SwiftUI reports the real one. Usually `rearm` already
    /// left the panel at that size with the field cleared, so this is one `orderFront`
    /// (~5–10 ms); a relayout (~10–20 ms) only happens when the Allume window changed size.
    func showPanel(expectedRows: Int? = nil) {
        guard let window else { return }
        if let n = expectedRows { contentHeight = PanelMetrics.height(forRows: n) }
        anchorHeight = contentHeight
        let t0 = Date()
        let frame = panelFrame(for: window.frame)
        var relaid = false
        if panel.frame != frame {
            relaid = panel.frame.size != frame.size
            panel.setFrame(frame, display: relaid)
        }
        let t1 = Date()
        panel.makeKeyAndOrderFront(nil)
        let t2 = Date()
        NotificationCenter.default.post(name: .panelShown, object: nil)
        Log.info("panel shown at \(panel.frame); setFrame \(Int(t1.timeIntervalSince(t0) * 1000)) ms\(relaid ? " (relaid)" : ""), orderFront \(Int(t2.timeIntervalSince(t1) * 1000)) ms")
    }

    /// Test hook: renders the panel's content view into a PNG at `path`.
    func snapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)); Log.info("panel snapshot → \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))") }
        catch { Log.info("panel snapshot failed: \(error)") }
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        Log.info("panel hidden")
        rearm()
    }

    /// Puts the hidden panel into the state the next ⌘K wants: field cleared, every command
    /// listed, frame at that height. Done now, while nobody is waiting, so `showPanel` has
    /// nothing left to lay out (see its timings).
    private func rearm() {
        NotificationCenter.default.post(name: .panelReset, object: nil)
        contentHeight = PanelMetrics.height(forRows: CommandCatalog.specs.count)
        anchorHeight = contentHeight
        if let w = window { panel.setFrame(panelFrame(for: w.frame), display: true) }
    }

    /// Anchored at the top (just under Allume's title bar), so growing or shrinking only moves
    /// the bottom edge; never taller than the space left in the Allume window.
    /// Centered in the Allume window (at the height it opened with), clamped to stay below
    /// the title bar and inside the window.
    private func panelFrame(for w: CGRect) -> CGRect {
        let s = Self.panelSize
        let maxTop = w.maxY - Self.topInset
        let top = min(maxTop, w.midY + anchorHeight / 2)
        let height = min(contentHeight, max(120, top - w.minY - 16))
        return CGRect(x: w.midX - s.width / 2, y: top - height, width: s.width, height: height)
    }
}
