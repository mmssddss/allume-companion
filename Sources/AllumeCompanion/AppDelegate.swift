import AppKit
import Carbon
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private var tracker = AllumeTracker()
    private var boardWatcher = BoardWatcher()
    private var hotKey: HotKey?
    private var runner: CommandRunner!
    private var overlay: OverlayController!
    private var trustTimer: Timer?
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner = CommandRunner(state: state)
        overlay = OverlayController(state: state, runner: runner)
        setupStatusItem()
        requestAccessibility()

        tracker.onChange = { [weak self] info in
            Task { @MainActor in
                Log.info("allume window: \(info.map { "\($0.frame) active=\($0.isActive)" } ?? "none")")
                self?.state.allumeRunning = info != nil
                self?.overlay.update(window: info)
            }
        }
        tracker.start()

        boardWatcher.onChange = { [weak self] id, title in
            self?.state.boardId = id
            self?.state.boardTitle = title
        }
        boardWatcher.start()

        // ⌘⇧P: kVK_ANSI_P = 0x23
        hotKey = HotKey(keyCode: 0x23, modifiers: UInt32(cmdKey | shiftKey))
        hotKey?.action = { [weak self] in self?.readSelectionAndShow() }

        // Test hook: `kill -USR1 $(pgrep -x AllumeCompanion)` behaves like pressing ⌘⇧P.
        signal(SIGUSR1, SIG_IGN)
        usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1Source?.setEventHandler { [weak self] in self?.readSelectionAndShow() }
        usr1Source?.resume()
        // Test hook: SIGUSR2 runs "排成 N 列" on the current selection, like clicking the button.
        signal(SIGUSR2, SIG_IGN)
        usr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        usr2Source?.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.runner.gatherGrid(columns: self.state.columns); Log.info("log:\n" + self.state.log) }
        }
        usr2Source?.resume()

        NotificationCenter.default.addObserver(forName: .togglePanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.overlay.togglePanel() }
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
            }
            tracker.refresh()
            overlay.update(window: tracker.currentWindow())
            overlay.showPanel()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Allume Companion")
        let menu = NSMenu()
        menu.addItem(withTitle: "读取选中并打开面板  ⌘⇧P", action: #selector(menuRead), keyEquivalent: "")
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
