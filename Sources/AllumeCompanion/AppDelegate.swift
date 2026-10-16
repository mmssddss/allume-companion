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
    private var boardIndex: BoardIndex!
    private var boardModel: BoardModel!
    private var trustTimer: Timer?
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?
    private var infoSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner = CommandRunner(state: state)
        overlay = OverlayController(state: state, runner: runner)
        // Current-board model: the index maps the window title to a board id (cached in
        // boards.json, recrawled in the background), the model holds that board's cards.
        boardIndex = BoardIndex()
        boardModel = BoardModel(index: boardIndex, thumbnails: runner.thumbnails)
        boardModel.onLoaded = { [weak self] in self?.runner.refreshSelectionFromModel() }
        runner.boardModel = boardModel
        boardIndex.refresh(reason: "launch")
        overlay.prewarm()
        setupStatusItem()
        requestAccessibility()

        tracker.onChange = { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                Log.info("allume window: \(info.map { "\($0.frame) active=\($0.isActive) title=\($0.title)" } ?? "none")")
                self.state.allumeRunning = info != nil
                self.state.boardTitle = info?.title ?? ""
                self.boardModel.allumeActive = info?.isActive ?? false
                if let title = info?.title { self.boardModel.setTitle(title) }
                self.updateHotKey(allumeActive: info?.isActive ?? false)
                self.overlay.update(window: info)
            }
        }
        tracker.start()

        // Allume answered the ⌘C after the wait had given up: if the panel is still open with
        // nothing selected, take the cards as if they had arrived in time.
        SelectionReader.onLateSelection = { [weak self] cards in
            guard let self, self.overlay.isPanelVisible, self.state.selectedCardIds.isEmpty, !cards.isEmpty else { return }
            self.state.selectedCardIds = cards.map(\.id)
            self.state.selectionFromAllume = true
            self.state.selectionMessage = ""
            self.state.appendLog("读取选中（迟到）：\(cards.count) 张 " + cards.map(\.id).joined(separator: ", "))
            Task { @MainActor in
                await self.runner.describeSelection()
                await self.boardModel.refreshOthers(containing: self.state.selectedCardIds, reason: "late selection")
            }
        }

        // ⌘K: kVK_ANSI_K = 0x28. Registered only while Allume is frontmost (see tracker.onChange)
        // so other apps keep their own ⌘K.
        hotKey = HotKey(keyCode: 0x28, modifiers: UInt32(cmdKey))
        hotKey?.action = { [weak self] in
            guard let self else { return }
            // ⌘K toggles: closes the panel when it is up, otherwise reads the selection and opens it.
            if self.overlay.isPanelVisible { self.overlay.hidePanel() } else { self.readSelectionAndShow() }
        }

        // Test hook: `kill -USR1 $(pgrep -x AllumeCompanion)` behaves like pressing ⌘K. With
        // `ALLUME_SELECT_IDS` set it only toggles the panel, keeping the preset selection
        // instead of re-reading it from Allume.
        let env = ProcessInfo.processInfo.environment
        let presetSelection = !(env["ALLUME_SELECT_IDS"] ?? "").isEmpty
        signal(SIGUSR1, SIG_IGN)
        usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1Source?.setEventHandler { [weak self] in
            guard let self else { return }
            if presetSelection {
                if self.overlay.isPanelVisible { self.overlay.hidePanel() } else {
                    var stats = HotKeyStats()
                    self.tracker.refresh()
                    self.overlay.update(window: self.tracker.currentWindow())
                    self.overlay.showPanel()
                    stats.panelShown()
                    // `ALLUME_SNAPSHOT=/path.png` also writes a rendering of the panel there
                    // (screencapture needs Screen Recording; this does not).
                    if let path = env["ALLUME_SNAPSHOT"], !path.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.overlay.snapshot(to: path) }
                    }
                    // Re-describe the preset selection too, so the ⌘K statistics are measurable
                    // with the hook (the ids themselves are kept; Allume is not asked).
                    Task { @MainActor in
                        Task { await self.boardModel.refresh(reason: "panel opened") }
                        await self.runner.describeSelection()
                        stats.described(self.state.selectedCards)
                        await self.boardModel.refreshOthers(containing: self.state.selectedCardIds, reason: "panel opened")
                    }
                }
            } else {
                self.hotKey?.action?()
            }
        }
        usr1Source?.resume()
        // Test hook: `ALLUME_SELECT_IDS=a,b,c` pre-fills the selection without going through ⌘C.
        if let ids = env["ALLUME_SELECT_IDS"], !ids.isEmpty {
            state.selectedCardIds = ids.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            state.selectionFromAllume = false
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

    /// ⌘K: the panel goes up first (a few ms), then the clipboard round trip fills in the
    /// selection; a timeout (nothing selected) therefore no longer delays the panel by 300 ms.
    func readSelectionAndShow() {
        Task { @MainActor in
            var stats = HotKeyStats()
            state.selectionPending = true
            state.selectedCardIds = []
            state.selectedCards = []
            tracker.refresh()   // 1–2 ms: the AX round trip is not where ⌘K's time goes
            overlay.update(window: tracker.currentWindow())
            overlay.showPanel(expectedRows: CommandCatalog.specs.count)
            stats.panelShown()
            do {
                let cards = try await SelectionReader.capture(pid: tracker.pid)
                state.selectedCardIds = cards.map(\.id)
                state.selectionFromAllume = true
                state.selectionMessage = cards.isEmpty ? "⌘C 后剪贴板里没有 Allume 卡片" : ""
                Log.info("selection: \(cards.count) cards after \(Int(Date().timeIntervalSince(stats.t0) * 1000)) ms: \(cards.map(\.id))")
                state.appendLog("读取选中：\(cards.count) 张 " + cards.map(\.id).joined(separator: ", "))
            } catch {
                state.selectedCardIds = []
                state.selectionMessage = error.localizedDescription
                state.appendLog("读取选中失败：\(error.localizedDescription)")
                Log.info("selection failed after \(Int(Date().timeIntervalSince(stats.t0) * 1000)) ms: \(error.localizedDescription)")
            }
            state.selectionPending = false
            // The panel is one of the model's refresh points; it runs alongside describing
            // the selection (which uses the model as it is now) and re-describes once done.
            // Boards the selection is on besides the current one are reloaded afterwards, so
            // a selection inside an inline sub-board is also fresh for the undo snapshot.
            Task { await boardModel.refresh(reason: "panel opened") }
            await runner.describeSelection()
            stats.described(state.selectedCards)
            await boardModel.refreshOthers(containing: state.selectedCardIds, reason: "panel opened")
        }
    }

    // MARK: - ⌘K statistics

    /// Counts CLI calls and time from ⌘K to the panel showing and to the card stack being
    /// described, and logs one line; the number to watch is "前台" on the second part.
    private struct HotKeyStats {
        let t0 = Date()
        let c0 = AllumeCLI.counts
        var shownMs = 0
        var shownCalls = AllumeCLI.Counts()

        mutating func panelShown() {
            shownMs = Int(Date().timeIntervalSince(t0) * 1000)
            shownCalls = AllumeCLI.counts - c0
        }

        func described(_ cards: [CardSummary]) {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let d = AllumeCLI.counts - c0
            let known = cards.filter { !$0.kind.isEmpty }.count
            Log.info("⌘K 统计：面板显示 \(shownMs) ms（CLI 前台 \(shownCalls.foreground) 次，后台 \(shownCalls.background) 次）；"
                     + "卡片信息就绪 \(ms) ms（CLI 前台 \(d.foreground) 次，后台 \(d.background) 次），\(known)/\(cards.count) 张有标题")
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
