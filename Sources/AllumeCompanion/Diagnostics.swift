import AppKit
import Foundation

/// "复制诊断信息" (menu bar, 设置 → Allume): what a bug report needs, as plain text on the
/// clipboard — versions, setup, permissions and the end of the log. The companion leans on
/// undocumented Allume behaviour (the clipboard format, the window title), so the first question
/// for any report is which Allume it ran against.
@MainActor
enum Diagnostics {
    /// The Allume build the current release was checked against (also in the README).
    static let testedAllume = "4.0.2 (10836)"
    static let logLines = 80

    static func allumeVersion(_ setup: AllumeSetup) -> String? {
        guard let url = setup.appURL, let info = Bundle(url: url)?.infoDictionary else { return nil }
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        return info["CFBundleVersion"].map { "\(v) (\($0))" } ?? v
    }

    static func report(setup: AllumeSetup, writeMode: AllumeSetup.WriteMode, allumeRunning: Bool) -> String {
        let info = Bundle.main.infoDictionary
        let me = (info?["CFBundleShortVersionString"] as? String ?? "dev") + (info?["CFBundleVersion"].map { " (\($0))" } ?? "")
        let write: String
        switch writeMode {
        case .writable: write = "read-write"
        case .readOnly: write = "read-only"
        case .unknown: write = "unknown"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion   // the String form is localized
        let lines = [
            "Allume Companion \(me)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(Locale.preferredLanguages.first ?? "?")",
            "Allume \(allumeVersion(setup) ?? "not found") at \(setup.appURL?.path ?? "-"), bundle \(setup.bundleID ?? "-"), running \(allumeRunning)",
            "tested with Allume \(testedAllume)",
            "CLI \(setup.cliInstalled ? AllumeCLI.path : "not installed"), \(write)",
            "Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed")",
        ]
        let tail = (try? String(contentsOfFile: Log.path, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).suffix(logLines).joined(separator: "\n") } ?? "(no log)"
        // The log names boards and cards; say so before it goes into a public issue.
        return """
        \(String(localized: "（贴到 GitHub issue 之前请看一遍：日志里有白板和卡片的标题。）"))

        \(lines.joined(separator: "\n"))

        --- \(Log.path), last \(logLines) lines ---
        \(tail)
        """
    }

    static func copy(setup: AllumeSetup, writeMode: AllumeSetup.WriteMode, allumeRunning: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report(setup: setup, writeMode: writeMode, allumeRunning: allumeRunning), forType: .string)
        Log.info("diagnostics copied")
    }
}
