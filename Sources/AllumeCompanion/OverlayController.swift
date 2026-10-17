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
    /// ⌘⏎ / ⌥⏎ / ⇧⌥⏎ go to the panel view (complete / postpone the highlighted todo) before the
    /// field editor sees them: in a text field ⌥⏎ would insert a line break, and ⌘⏎ would be
    /// tried as a menu key equivalent first.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
            let mods = event.modifierFlags.intersection([.command, .option, .shift])
            if mods.contains(.command) || mods.contains(.option) {
                NotificationCenter.default.post(name: .panelModifiedReturn, object: mods.rawValue)
                return
            }
        }
        super.sendEvent(event)
    }
}

/// Owns the command panel: hidden by default, dropped down from the top of the Allume window
/// by ⌘K, dismissed by Esc, ⌘K again, clicking back into Allume, or Allume leaving the front.
@MainActor
final class OverlayController {
    let state: AppState
    let panel: OverlayPanel
    private var window: AllumeTracker.WindowInfo?

    static let panelSize = CGSize(width: PanelMetrics.width, height: PanelMetrics.maxHeight)
    /// True while the panel fades out: it is still on screen but already counts as closed
    /// (⌘K opens it again, cancelling the fade).
    private var hiding = false
    /// Bumped by every show and hide, so a fade-out that finishes after a new show does nothing.
    private var fadeGeneration = 0

    init(state: AppState, runner: CommandRunner) {
        self.state = state
        panel = Self.makePanel(size: Self.panelSize)
        let host = NSHostingView(rootView: CommandPanelView(state: state, runner: runner))
        if #available(macOS 26.0, *) {
            // Liquid Glass from AppKit (NSGlassEffectView), clipped to the rounded rect: see
            // `roundedClip` for why the clip is needed.
            let glass = NSGlassEffectView()
            glass.cornerRadius = PanelMetrics.cornerRadius
            glass.contentView = host
            panel.contentView = Self.roundedClip(glass)
        } else {
            panel.contentView = host
        }
        // Esc inside a navigation list goes back to the commands; from the commands it closes.
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if self.state.panelMode != .commands { self.state.panelMode = .commands } else { self.hidePanel() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    /// Wraps `view` in a layer that clips to the panel's rounded rect. The glass draws its own
    /// soft shadow past its shape; cut off by the square window edge, it left the corners ~6%
    /// black, so they showed grey and the window shadow came out square. Clipped, the corners are
    /// fully transparent and the window shadow follows the rounded shape.
    private static func roundedClip(_ view: NSView) -> NSView {
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = PanelMetrics.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        view.frame = clip.bounds
        view.autoresizingMask = [.width, .height]
        clip.addSubview(view)
        return clip
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

    var isPanelVisible: Bool { panel.isVisible && !hiding }

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
        var window = window
        // Test hook: `ALLUME_FAKE_WINDOW=x,y,w,h` (AppKit coordinates) stands in for Allume's
        // window frame, to see the panel over a full-screen or Split View window.
        if let fake = Self.fakeWindow, window != nil { window?.frame = fake }
        self.window = window
        guard let window, window.isActive || panel.isKeyWindow else {
            hidePanel()
            if let w = window { place(for: w.frame) }
            return
        }
        if panel.isVisible { panel.setFrame(panelFrame(for: window.frame), display: true) } else { place(for: window.frame) }
    }

    private static let fakeWindow: CGRect? = {
        let n = (ProcessInfo.processInfo.environment["ALLUME_FAKE_WINDOW"] ?? "").split(separator: ",").compactMap { Double($0) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
    }()

    /// Moves the hidden panel to where it would open; redraws only when the size changed.
    private func place(for windowFrame: CGRect) {
        let frame = panelFrame(for: windowFrame)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: panel.frame.size != frame.size)
    }

    /// One size, always (like Raycast): rows fill in from the top, so nothing about the window
    /// changes after it is up. It fades in; usually the frame is already right (`rearm`, `place`),
    /// so this is one `orderFront` (~5–10 ms), a relayout only when the Allume window changed size.
    func showPanel() {
        guard let window else { return }
        fadeGeneration += 1
        hiding = false
        let t0 = Date()
        let frame = panelFrame(for: window.frame)
        var relaid = false
        if panel.frame != frame {
            relaid = panel.frame.size != frame.size
            panel.setFrame(frame, display: relaid)
        }
        let t1 = Date()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelMetrics.fadeIn
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        let t2 = Date()
        NotificationCenter.default.post(name: .panelShown, object: nil)
        Log.info("panel shown at \(panel.frame); setFrame \(Int(t1.timeIntervalSince(t0) * 1000)) ms\(relaid ? " (relaid)" : ""), orderFront \(Int(t2.timeIntervalSince(t1) * 1000)) ms")
        captureFrames()
    }

    /// Test hook (`ALLUME_FRAMES=/dir`): after each show, grabs the panel's window every ~25 ms
    /// for 400 ms into `<dir>/show-<time>/frame-NN-<ms>-a<alpha%>.png`, to check that the opening
    /// never jumps. The app may capture its own window without Screen Recording;
    /// `CGWindowListCreateImage` is looked up with dlsym because the SDK marks it unavailable.
    /// The capture has neither the window's alpha (hence the file name) nor what is behind the glass.
    private func captureFrames() {
        guard let dir = ProcessInfo.processInfo.environment["ALLUME_FRAMES"], !dir.isEmpty else { return }
        let t0 = Date()
        let run = URL(fileURLWithPath: dir).appendingPathComponent("show-\(Int(t0.timeIntervalSince1970 * 1000))")
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        for i in 0..<16 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.025) { [self] in
                guard let png = Self.capturePNG(windowNumber: panel.windowNumber) else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let alpha = Int((panel.alphaValue * 100).rounded())
                try? png.write(to: run.appendingPathComponent(String(format: "frame-%02d-%03dms-a%03d.png", i, ms, alpha)))
            }
        }
    }

    /// PNG of one of this app's own windows, as the window server composites it (no Screen
    /// Recording needed for our own windows).
    static func capturePNG(windowNumber: Int) -> Data? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(sym, to: Capture.self)
        // optionIncludingWindow = 1 << 3, boundsIgnoreFraming = 1 << 0
        guard let img = capture(.null, 1 << 3, UInt32(windowNumber), 1 << 0)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// Test hook: renders the panel's content view into a PNG at `path`.
    func snapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)); Log.info("panel snapshot → \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))") }
        catch { Log.info("panel snapshot failed: \(error)") }
    }

    /// Fades out, then orders out and rearms; a show during the fade cancels it.
    func hidePanel() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        fadeGeneration += 1
        let generation = fadeGeneration
        Log.info("panel hidden")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelMetrics.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            guard self.fadeGeneration == generation else { return }
            self.hiding = false
            self.panel.orderOut(nil)
            self.rearm()
        }
    }

    /// Puts the hidden panel into the state the next ⌘K wants: field cleared, frame in place.
    /// Done now, while nobody is waiting, so `showPanel` has nothing left to lay out (see its timings).
    private func rearm() {
        NotificationCenter.default.post(name: .panelReset, object: nil)
        if let w = window { place(for: w.frame) }
    }

    /// Centred in the Allume window (see `PanelPlacement`: full screen, Split View, narrow windows).
    private func panelFrame(for w: CGRect) -> CGRect {
        let screen = PanelPlacement.screen(for: w, among: NSScreen.screens.map(\.frame))
        return PanelPlacement.frame(window: w, screen: screen, width: Self.panelSize.width, maxHeight: Self.panelSize.height)
    }
}
