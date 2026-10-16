import AppKit
import ApplicationServices

/// Follows the Allume main window (frame + active state) through the Accessibility API.
/// Frames are reported in AppKit screen coordinates (origin bottom-left of the primary display).
final class AllumeTracker {
    static let bundleID = "com.musesoftware.museios-setapp"

    struct WindowInfo: Equatable {
        var frame: CGRect
        var isActive: Bool
        /// Allume titles its window with the current board's name (e.g. "Project"), which is the
        /// only permission-free way to learn the current board: its container (and so
        /// `lastViewedDocumentId`) is unreadable from another app, see AllumeCLI.
        var title: String
    }

    var onChange: ((WindowInfo?) -> Void)?
    private(set) var app: NSRunningApplication?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var pollTimer: Timer?
    private var last: WindowInfo??

    var pid: pid_t? { app?.processIdentifier }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            nc.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        attachIfNeeded()
        // Safety net: AX notifications occasionally go missing (e.g. live-resize on some builds).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.attachIfNeeded()
            self?.refresh()
        }
    }

    @objc private func workspaceChanged(_ note: Notification) {
        let changed = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard changed?.bundleIdentifier == Self.bundleID || changed == nil else { return }
        if note.name == NSWorkspace.didTerminateApplicationNotification { detach() }
        attachIfNeeded()
        refresh()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        app = nil
    }

    func attachIfNeeded() {
        if let app, !app.isTerminated, observer != nil { return }
        guard AXIsProcessTrusted() else { return }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            detach(); return
        }
        app = running
        let element = AXUIElementCreateApplication(running.processIdentifier)
        appElement = element

        var obs: AXObserver?
        let err = AXObserverCreate(running.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AllumeTracker>.fromOpaque(refcon).takeUnretainedValue()
            me.refresh()
        }, &obs)
        guard err == .success, let obs else {
            Log.info("AXObserverCreate failed: \(err.rawValue)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                     kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification,
                     kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    func refresh() {
        let info = currentWindow()
        if case .some(let prev) = last, prev == info { return }
        last = .some(info)
        onChange?(info)
    }

    /// Frame of Allume's focused (or main) window, nil when none is visible.
    func currentWindow() -> WindowInfo? {
        guard let app, !app.isTerminated, let appElement else { return nil }
        if app.isHidden { return nil }
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            _ = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { return nil }
        guard let pos: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize) else { return nil }
        // AX coordinates: origin top-left of the primary display. Convert to AppKit.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        return WindowInfo(frame: frame, isActive: app.isActive, title: titleRef as? String ?? "")
    }

    private func axValue<T>(_ element: AXUIElement, _ attr: String, _ type: AXValueType) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        let value = ref as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        switch type {
        case .cgPoint:
            var p = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &p) ? (p as! T) : nil
        case .cgSize:
            var s = CGSize.zero
            return AXValueGetValue(value, .cgSize, &s) ? (s as! T) : nil
        default:
            return nil
        }
    }
}
