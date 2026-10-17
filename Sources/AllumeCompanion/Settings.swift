import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// What the 设置 window shows and can do. AppDelegate fills in the actions; `refresh` re-reads
/// the live state (permissions, login item, todo index) every second while the window is open,
/// so turning something on in 系统设置 shows up here without reopening.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var setup = AllumeSetup()
    @Published var allumeRunning = false
    @Published var cliWrite: AllumeSetup.WriteMode = .unknown
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var loginError = ""
    @Published var axTrusted = false
    @Published var notifications: DueReminders.Permission = .unavailable
    // Read in `refresh`: this model is made before AppDelegate registers the defaults.
    @Published var remindersEnabled = true
    @Published var reminderTime = Date()
    @Published var todoCount = 0
    @Published var overdueCount = 0
    @Published var boardCount = 0
    @Published var scannedAt: Date?
    @Published var scanning = false
    @Published var thumbnailsCleared = false
    /// What the last "发一条测试通知" did.
    @Published var testResult = ""

    var rescanTodos: () -> Void = {}
    var sendTestNotification: () -> Void = {}
    var clearThumbnails: () -> Void = {}
    /// Reminder on/off or time changed: reschedule.
    var remindersChanged: () -> Void = {}
    /// Re-detects Allume and its CLI (and lets AppDelegate act on a change); with whether Allume
    /// is running and the last known CLI write mode.
    var setupFacts: () -> (AllumeSetup, Bool, AllumeSetup.WriteMode) = { (AllumeSetup(), false, .unknown) }
    /// Asks the CLI again whether it may write (the answer lands through `setupFacts`).
    var checkWriteMode: () -> Void = {}
    /// Todo index facts: (todos, overdue, scanned at, scanning, boards).
    var indexFacts: () -> (Int, Int, Date?, Bool, Int) = { (0, 0, nil, false, 0) }

    func refresh() {
        let (s, running, write) = setupFacts()
        if s != setup { setup = s }
        if running != allumeRunning { allumeRunning = running }
        if write != cliWrite { cliWrite = write }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        axTrusted = AXIsProcessTrusted()
        if remindersEnabled != ReminderSettings.enabled { remindersEnabled = ReminderSettings.enabled }
        let time = ReminderSettings.fireDate(on: Date())
        if !Calendar.current.isDate(time, equalTo: reminderTime, toGranularity: .minute) { reminderTime = time }
        (todoCount, overdueCount, scannedAt, scanning, boardCount) = indexFacts()
        Task { notifications = await DueReminders.permission() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginError = ""
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("settings: launch at login \(on ? "on" : "off") → \(SMAppService.mainApp.status.rawValue)")
        } catch {
            loginError = error.localizedDescription
            Log.info("settings: launch at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func setRemindersEnabled(_ on: Bool) {
        ReminderSettings.enabled = on
        remindersEnabled = on
        remindersChanged()
    }

    func setReminderTime(_ date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard c.hour != ReminderSettings.hour || c.minute != ReminderSettings.minute else { return }
        ReminderSettings.hour = c.hour ?? 9
        ReminderSettings.minute = c.minute ?? 0
        reminderTime = date
        remindersChanged()
    }
}

/// The tabs of the 设置 window, in toolbar order.
enum SettingsTab: String, CaseIterable {
    case general, allume, reminders, data, about

    var title: String {
        switch self {
        case .general: return "通用"
        case .allume: return "Allume"
        case .reminders: return "提醒"
        case .data: return "数据"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .allume: return "checklist"
        case .reminders: return "bell"
        case .data: return "internaldrive"
        case .about: return "info.circle"
        }
    }
}

/// The 设置 window (menu bar → 设置… ⌘,), laid out like Allume's own: toolbar tabs with icons,
/// the window titled after the tab and sized to it. It activates the app when shown, since a
/// menu bar app has no Dock icon to come forward with.
@MainActor
final class SettingsWindowController {
    let model = SettingsModel()
    private var window: NSWindow?
    private var tabs: SettingsTabController?
    private var timer: Timer?

    /// `tab`: which one to show (the Allume tab when something is missing); nil keeps the current one.
    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let tabs = SettingsTabController()
            tabs.tabStyle = .toolbar
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: SettingsPage(tab: t, model: model))
                host.sizingOptions = .intrinsicContentSize   // fittingSize = the page's SwiftUI size
                host.title = t.title
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                item.identifier = t.rawValue
                tabs.addTabViewItem(item)
            }
            let w = SettingsWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.timer?.invalidate(); self?.timer = nil
                    self?.model.thumbnailsCleared = false; self?.model.testResult = ""
                }
            }
            window = w
            self.tabs = tabs
            tabs.fitWindow(animate: false)
            w.center()
        }
        if let tab, let i = SettingsTab.allCases.firstIndex(of: tab) { tabs?.selectedTabViewItemIndex = i }
        model.refresh()
        if model.setup.ready, model.allumeRunning, model.cliWrite != .writable { model.checkWriteMode() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil) // no focus ring on the first control
    }

    var windowNumber: Int? { window?.windowNumber }
}

/// Resizes the window to the selected page, keeping its top edge where it is.
private final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animate: true)
    }

    func fitWindow(animate: Bool) {
        guard let page = tabViewItems[safe: selectedTabViewItemIndex]?.viewController, let window = view.window else { return }
        let size = page.view.fittingSize
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = window.frame
        f.origin.y += f.height - frame.height
        f.size = frame.size
        window.setFrame(f, display: true, animate: animate)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// ⌘W closes it: the app has no main menu (it is a menu bar app), so no Close item would.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One tab's content, in Allume's plain style: label rows, checkboxes with a grey line of
/// explanation under them, groups split by a hairline. Fixed width; the height is what it needs.
struct SettingsPage: View {
    let tab: SettingsTab
    @ObservedObject var model: SettingsModel

    static let site = URL(string: "https://maverickli.org")!
    static let github = URL(string: "https://github.com/mmssddss/allume-companion")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch tab {
            case .general: general
            case .allume: allume
            case .reminders: reminders
            case .data: data
            case .about: about
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Pages

    @ViewBuilder private var general: some View {
        checkbox("登录时自动打开", detail: "开机后自动在菜单栏待命",
                 isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        if model.loginNeedsApproval {
            HStack {
                Text("需要在系统设置的登录项里允许").foregroundStyle(.secondary)
                Button("打开登录项…") { SMAppService.openSystemSettingsLoginItems() }
            }
            .padding(.leading, 22)
        }
        if !model.loginError.isEmpty {
            Text(model.loginError).font(.callout).foregroundStyle(.orange).padding(.leading, 22)
        }
        Divider()
        Text("权限").font(.headline)
        statusRow("辅助功能", ok: model.axTrusted,
                  status: model.axTrusted ? "已允许" : "未允许，读不到选中的卡片") {
            if !model.axTrusted {
                Button("打开设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        statusRow("通知", ok: model.notifications == .allowed, status: notificationStatus) {
            if model.notifications != .allowed && model.notifications != .unavailable {
                Button("打开设置…") { DueReminders.openSettings() }
            }
        }
        note("辅助功能用来给 Allume 发 ⌘C 读选中的卡片；通知只用于到期提醒。")
        Divider()
        note("在 Allume 里按 ⌘K 打开面板。")
    }

    @ViewBuilder private var allume: some View {
        statusRow("Allume", ok: model.setup.appInstalled,
                  status: model.setup.appURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "没找到") {
            if !model.setup.appInstalled { Link("前往 allume.com", destination: AllumeSetup.website) }
        }
        statusRow("正在运行", ok: model.allumeRunning, status: model.allumeRunning ? "是" : "没在运行") {
            if model.setup.appInstalled && !model.allumeRunning { openAllumeButton }
        }
        statusRow("命令行工具", ok: model.setup.cliInstalled, status: model.setup.cliInstalled ? AllumeCLI.path : "没装") {
            if model.setup.appInstalled && !model.setup.cliInstalled && model.allumeRunning { openAllumeButton }
        }
        statusRow("写入权限", ok: model.cliWrite == .writable, status: writeStatus) {
            if model.setup.ready && model.allumeRunning && model.cliWrite != .writable {
                Button("重新检查") { model.checkWriteMode() }
            }
        }
        Divider()
        Text(setupHint)
            .font(.callout)
            .foregroundStyle(allReady ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var reminders: some View {
        checkbox("到期当天提醒", detail: "带日期的待办，到那天发一条系统通知，点开跳到它所在的白板",
                 isOn: Binding(get: { model.remindersEnabled }, set: { model.setRemindersEnabled($0) }))
        HStack(spacing: 8) {
            Text("提醒时间：")
            DatePicker("", selection: Binding(get: { model.reminderTime }, set: { model.setReminderTime($0) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.leading, 22)
        .disabled(!model.remindersEnabled)
        Divider()
        HStack(spacing: 10) {
            Button("发一条测试通知") { model.testResult = ""; model.sendTestNotification() }
                .disabled(model.notifications == .unavailable)
            if !model.testResult.isEmpty {
                Text(model.testResult).font(.callout)
                    .foregroundStyle(model.notifications == .allowed ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        note("待办的写法：文字卡正文第一行 @todo(due: 2026-10-20) 内容")
    }

    @ViewBuilder private var data: some View {
        labeled("待办：") {
            Text("\(model.todoCount) 条" + (model.overdueCount > 0 ? "，\(model.overdueCount) 条到期" : ""))
            Button(model.scanning ? "扫描中…" : "重新扫描") { model.rescanTodos() }.disabled(model.scanning)
        }
        note(scanText + "，共 \(model.boardCount) 块白板。")
        Divider()
        labeled("缩略图：") {
            Button(model.thumbnailsCleared ? "已清空" : "清空缓存") {
                model.clearThumbnails()
                model.thumbnailsCleared = true
            }
            .disabled(model.thumbnailsCleared)
        }
        note("子白板和图片的缩略图会在下次用到时重新生成。")
        Divider()
        labeled("日志：") {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.path)]) }
        }
    }

    @ViewBuilder private var about: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allume Companion").font(.title3.weight(.semibold))
                Text(version).foregroundStyle(.secondary)
                Text("Maverick Li 制作 · MIT 许可").foregroundStyle(.secondary)
            }
        }
        Divider()
        labeled("网站：") { Link("maverickli.org", destination: Self.site) }
        labeled("源代码：") { Link("github.com/mmssddss/allume-companion", destination: Self.github) }
    }

    // MARK: - Pieces

    /// A checkbox with a grey line of explanation under it, like Allume's 会员 tab.
    private func checkbox(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
            Text(detail).font(.callout).foregroundStyle(.secondary).padding(.leading, 22)
        }
    }

    /// "名字：" then controls, like Allume's "邮箱： … [登出]".
    private func labeled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(_ name: String, ok: Bool, status: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(name)
            Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            action()
        }
        .frame(minHeight: 22)
    }

    private var openAllumeButton: some View {
        Button("打开 Allume") {
            if let url = model.setup.appURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
        }
    }

    private var allReady: Bool { model.setup.ready && model.allumeRunning && model.cliWrite == .writable }

    private var writeStatus: String {
        switch model.cliWrite {
        case .writable: return "可写"
        case .readOnly: return "只读，排列、改大小、添加待办都会失败"
        case .unknown:
            if !model.setup.cliInstalled { return "装好命令行工具后检查" }
            return model.allumeRunning ? "检查中…" : "打开 Allume 后检查"
        }
    }

    /// The next thing to do, in order: install Allume, run it, install the CLI, make it writable.
    private var setupHint: String {
        if !model.setup.appInstalled { return "第 1 步：Companion 的所有操作都经过 Allume 和它的命令行工具，先装 Allume（allume.com 或 Setapp）。" }
        if !model.allumeRunning { return "第 2 步：打开 Allume。命令行工具要连着运行中的 Allume 才能用。" }
        if !model.setup.cliInstalled { return "第 3 步：在 Allume 的设置 → CLI 里安装命令行工具，装好后这里会自动变绿。" }
        if model.cliWrite == .readOnly { return "第 4 步：在 Allume 的设置 → CLI 里允许写入（read-write），再点「重新检查」。" }
        if model.cliWrite == .unknown { return "正在问命令行工具能不能写入…" }
        return "都准备好了。在 Allume 里按 ⌘K 打开面板。"
    }

    private var notificationStatus: String {
        switch model.notifications {
        case .allowed: return "已允许"
        case .denied: return "已关闭，到期不会提醒"
        case .notAsked: return "还没问过"
        case .unavailable: return "只在 .app 里可用"
        }
    }

    private var scanText: String {
        if model.scanning { return "正在扫描所有白板" }
        guard let t = model.scannedAt else { return "还没扫描过" }
        return "上次扫描 " + t.formatted(date: .omitted, time: .shortened) + "，每 15 分钟自动扫一次"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let b = info?["CFBundleVersion"] as? String
        return "版本 \(v)" + (b.map { " (\($0))" } ?? "")
    }
}
