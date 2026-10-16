import AppKit
import Carbon
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private var tracker = AllumeTracker()
    private var hotKey: HotKey?
    private var runner: CommandRunner!
    private var overlay: OverlayController!
    private var trustTimer: Timer?
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?
    private var infoSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner = CommandRunner(state: state)
        overlay = OverlayController(state: state, runner: runner)
        setupStatusItem()
        requestAccessibility()

        tracker.onChange = { [weak self] info in
            Task { @MainActor in
                Log.info("allume window: \(info.map { "\($0.frame) active=\($0.isActive) title=\($0.title)" } ?? "none")")
                self?.state.allumeRunning = info != nil
                self?.state.boardTitle = info?.title ?? ""
                self?.updateHotKey(allumeActive: info?.isActive ?? false)
                self?.overlay.update(window: info)
            }
        }
        tracker.start()

        // ⌘K: kVK_ANSI_K = 0x28. Registered only while Allume is frontmost (see tracker.onChange)
        // so other apps keep their own ⌘K.
        hotKey = HotKey(keyCode: 0x28, modifiers: UInt32(cmdKey))
        hotKey?.action = { [weak self] in
            guard let self else { return }
            // ⌘K toggles: closes the panel when it is up, otherwise reads the selection and opens it.
            if self.overlay.isPanelVisible { self.overlay.hidePanel() } else { self.readSelectionAndShow() }
        }

        // Test hook: `kill -USR1 $(pgrep -x AllumeCompanion)` behaves like pressing ⌘K.
        signal(SIGUSR1, SIG_IGN)
        usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1Source?.setEventHandler { [weak self] in self?.hotKey?.action?() }
        usr1Source?.resume()
        // Test hook: `ALLUME_SELECT_IDS=a,b,c` pre-fills the selection without going through ⌘C.
        let env = ProcessInfo.processInfo.environment
        if let ids = env["ALLUME_SELECT_IDS"], !ids.isEmpty {
            state.selectedCardIds = ids.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            state.appendLog("测试：预设选中 \(state.selectedCardIds.count) 张 " + state.selectedCardIds.joined(separator: ", "))
            Task { @MainActor in await runner.describeSelection() }
        }
        // Test hook: SIGUSR2 runs a panel command on the current selection, like clicking its button.
        // `ALLUME_USR2` is a command query exactly as one would type it in the panel
        // ("grid 4", "resize 300x200", "一行", "undo"); default "排成 3 列".
        signal(SIGUSR2, SIG_IGN)
        usr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        usr2Source?.setEventHandler { [weak self] in
            guard let self else { return }
            if env["ALLUME_AXDUMP"] != nil, let pid = self.tracker.pid {
                AXDump.dump(pid: pid); return
            }
            Task { @MainActor in
                let query = env["ALLUME_USR2"] ?? "排成 3 列"
                if let match = CommandCatalog.matches(for: query).first {
                    Log.info("test: \"\(query)\" → \(match.title)")
                    await self.runner.run(match.kind)
                } else {
                    Log.info("test: no command matches \"\(query)\"")
                }
                Log.info("panel log:\n" + self.state.log)
            }
        }
        usr2Source?.resume()
        // Test hook: SIGINFO (`kill -INFO`) presses "撤销".
        signal(SIGINFO, SIG_IGN)
        infoSource = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        infoSource?.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.runner.undo()
                Log.info("panel log:\n" + self.state.log)
            }
        }
        infoSource?.resume()

    }

    private func updateHotKey(allumeActive: Bool) {
        guard let hotKey else { return }
        let wantRegistered = allumeActive || overlay.panel.isKeyWindow
        if wantRegistered != hotKey.isRegistered {
            wantRegistered ? hotKey.register() : hotKey.unregister()
            Log.info("hotkey ⌘K \(wantRegistered ? "registered" : "unregistered")")
        }
    }

    // MARK: - Accessibility

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        state.axTrusted = AXIsProcessTrustedWithOptions(opts)
        Log.info("accessibility trusted: \(state.axTrusted)")
        if !state.axTrusted {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.state.axTrusted = true
                    Log.info("accessibility granted")
                    self.trustTimer?.invalidate()
                    self.tracker.attachIfNeeded()
                    self.tracker.refresh()
                }
            }
        }
    }

    // MARK: - Selection

    func readSelectionAndShow() {
        Task { @MainActor in
            do {
                let cards = try await SelectionReader.capture(pid: tracker.pid)
                state.selectedCardIds = cards.map(\.id)
                state.selectionMessage = cards.isEmpty ? "⌘C 后剪贴板里没有 Allume 卡片" : ""
                Log.info("selection: \(cards.count) cards: \(cards.map(\.id))")
                state.appendLog("读取选中：\(cards.count) 张 " + cards.map(\.id).joined(separator: ", "))
            } catch {
                state.selectedCardIds = []
                state.selectionMessage = error.localizedDescription
                state.appendLog("读取选中失败：\(error.localizedDescription)")
                Log.info("selection failed: \(error.localizedDescription)")
            }
            tracker.refresh()
            overlay.update(window: tracker.currentWindow())
            overlay.showPanel()
            await runner.describeSelection()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Allume Companion")
        let menu = NSMenu()
        menu.addItem(withTitle: "读取选中并打开面板  ⌘K", action: #selector(menuRead), keyEquivalent: "")
        menu.addItem(withTitle: "打开辅助功能设置…", action: #selector(openAXSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Allume Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuRead() { readSelectionAndShow() }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
