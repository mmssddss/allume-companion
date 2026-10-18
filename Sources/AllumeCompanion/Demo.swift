import Foundation

/// Demo mode for recording the feature videos: `ALLUME_DEMO_ROOT=<board document id>` makes that
/// board stand in for the workspace. Allume has one workspace per user and the CLI cannot make
/// another, so without this the panel would show the recorder's real boards and todos.
///
/// With it: board search, 最近去过 and 全部待办 list only boards at or below the demo board;
/// 回首页 opens it; 今天 / 本月 / 新建项目 build workspace-Companion on it, registered in
/// companion-demo.json; visits go to trail-demo.json; no reminders are scheduled. Everything
/// else (crawling the whole index, the todo scan) runs as usual.
enum Demo {
    static let root: String? = {
        let id = ProcessInfo.processInfo.environment["ALLUME_DEMO_ROOT"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }()

    static var isOn: Bool { root != nil }

    /// `name.json` → `name-demo.json` in demo mode, so a recording leaves the real files alone.
    static func file(_ name: String) -> String {
        guard isOn else { return name + ".json" }
        return name + "-demo.json"
    }
}
