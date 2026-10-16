# Allume Companion

macOS 菜单栏 app，贴在 Allume 窗口上的浮层 + 命令面板，所有操作走 `/usr/local/bin/allume` CLI。
读 README.md 了解原理、权限和脆弱点；下面只记对改代码有用的事。

## 跑起来

- `scripts/run.sh`：构建 release、打包到 `build/AllumeCompanion.app`、签名、`open`。改完代码就跑它。
- 日志在 `~/Library/Logs/AllumeCompanion.log`（`Log.info`），不要指望 `log show` 能看到 NSLog。
- 需要辅助功能权限；用 Apple Development 证书签名后权限跨构建保留，ad-hoc 不保留。

## 硬性约束

- 不截屏、不模拟点击 Allume；唯一允许模拟的按键是发给 Allume 的 ⌘C（读选中用）。
- 对 Allume 的所有读写都通过 CLI（`AllumeCLI.run`），命令和输出要显示在面板日志里。
- 浮层窗口必须是 `.nonactivatingPanel`，不能抢 Allume 的前台。

## 已知事实（实测）

- `lastViewedDocumentId` 跨 app 用 CFPreferences 读是 nil，必须读容器里的 plist 文件。
- `allume search` 不接受空 query；白板标题只能靠 `board-content --kinds subBoard` 从根白板 BFS。
- `allume card-content <白板id>` 报 "No card"。
- 无 Xcode 工程；SwiftPM + 手写 Info.plist 足够。Swift 6.3 编译器、语言模式 5。
