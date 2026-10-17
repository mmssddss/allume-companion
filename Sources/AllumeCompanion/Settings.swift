import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// What the 设置 window shows and can do. AppDelegate fills in the actions; `refresh` re-reads
/// the live state (permissions, login item, todo index) every second while the window is open,
/// so turning something on in 系统设置 shows up here without reopening.
@MainActor
final class SettingsModel: ObservableObject {
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
    /// Todo index facts: (todos, overdue, scanned at, scanning, boards).
    var indexFacts: () -> (Int, Int, Date?, Bool, Int) = { (0, 0, nil, false, 0) }

    func refresh() {
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

/// The 设置 window (menu bar → 设置… ⌘,): a normal titled window, since the app has no Dock icon
/// it activates the app when shown.
@MainActor
final class SettingsWindowController {
    let model = SettingsModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = SettingsWindow(contentViewController: host)
            w.title = "Allume Companion 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.timer?.invalidate(); self?.timer = nil }
            }
            window = w
            w.center()
        }
        model.refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil) // no focus ring on the first switch
    }

    var windowNumber: Int? { window?.windowNumber }
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    static let site = URL(string: "https://maverickli.org")!
    static let github = URL(string: "https://github.com/mmssddss/allume-companion")!

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时自动打开", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    HStack {
                        Text("需要在系统设置的登录项里允许").foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if !model.loginError.isEmpty {
                    Text(model.loginError).font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("打开面板", value: "在 Allume 里按 ⌘K")
            }

            Section {
                permissionRow("辅助功能", ok: model.axTrusted,
                              status: model.axTrusted ? "已允许" : "未允许，读不到选中的卡片",
                              button: "打开设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                permissionRow("通知", ok: model.notifications == .allowed,
                              status: notificationStatus, button: "打开设置…") { DueReminders.openSettings() }
            } header: {
                Text("权限")
            } footer: {
                Text("辅助功能用来给 Allume 发 ⌘C 读选中；通知只用于到期提醒。").font(.caption).foregroundStyle(.secondary)
            }

            Section("到期提醒") {
                Toggle("到期当天提醒", isOn: Binding(get: { model.remindersEnabled }, set: { model.setRemindersEnabled($0) }))
                DatePicker("提醒时间", selection: Binding(get: { model.reminderTime }, set: { model.setReminderTime($0) }),
                           displayedComponents: .hourAndMinute)
                    .disabled(!model.remindersEnabled)
                HStack {
                    Text("写法：卡片正文第一行 @todo(due: 2026-10-20) 内容").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("发一条测试通知") { model.testResult = ""; model.sendTestNotification() }
                        .disabled(model.notifications == .unavailable)
                }
                if !model.testResult.isEmpty {
                    Text(model.testResult).font(.caption)
                        .foregroundStyle(model.notifications == .allowed ? Color.secondary : Color.orange)
                }
            }

            Section("待办与缓存") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.todoCount) 条待办" + (model.overdueCount > 0 ? "，\(model.overdueCount) 条到期" : "") + " · \(model.boardCount) 块白板")
                        Text(scanText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.scanning ? "扫描中…" : "重新扫描") { model.rescanTodos() }
                        .disabled(model.scanning)
                }
                HStack {
                    Text("缩略图缓存")
                    Spacer()
                    Button(model.thumbnailsCleared ? "已清空" : "清空") {
                        model.clearThumbnails()
                        model.thumbnailsCleared = true
                    }
                    .disabled(model.thumbnailsCleared)
                }
                HStack {
                    Text("日志")
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.path)]) }
                }
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allume Companion").font(.system(size: 15, weight: .semibold))
                        Text(version).font(.caption).foregroundStyle(.secondary)
                        Text("Maverick Li 制作 · MIT 许可").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                LabeledContent("网站") { Link("maverickli.org", destination: Self.site) }
                LabeledContent("源代码") { Link("github.com/mmssddss/allume-companion", destination: Self.github) }
            } header: {
                Text("关于")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 880)
        .onDisappear { model.thumbnailsCleared = false; model.testResult = "" }
    }

    private func permissionRow(_ name: String, ok: Bool, status: String, button: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(name)
            Text(status).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !ok { Button(button, action: open) }
        }
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
        if model.scanning { return "正在扫描所有白板…" }
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
