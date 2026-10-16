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

- Allume 的容器和 group container 对伴生 app 及其子进程都不可读（按 responsible process 判定），所以
  `lastViewedDocumentId` 读不到；当前白板标题取 Allume 窗口的 AX 标题。
- CLI 自己是沙盒 app，直接 `Process` 启动时读不到 `isCLIReadOnly` → 一律只读（exit 7）；必须经 `open -W` 启动。
- `allume search` 不接受空 query；`allume card-content <白板id>` 报 "No card"。
- Allume 的 AX 树里卡片标题是 AXTextField 的 value（subBoard 也有），但没有选中状态，选中仍靠 ⌘C + 剪贴板。
- CLI 做的删除/移动在 Allume 里 ⌘Z 撤不掉（不经过它的 undo manager），只能 `undelete` / `card-move` 恢复；面板的"撤销"就是这么做的。
- `board-content` 只接受完整白板文档 id `<前缀>:<后缀>`，卡片 id 的 scope 前缀不够；`card-content <卡片id> -f json` 的
  `parentDocumentId` 给出父白板文档 id，`frame` 给出位置尺寸。`card-move` 接受小数坐标；`undelete` 会把卡片放回原 frame。
- 无 Xcode 工程；SwiftPM + 手写 Info.plist 足够。Swift 6.3 编译器、语言模式 5。
