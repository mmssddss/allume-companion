# Allume Companion

贴在 Allume（原 Muse）白板窗口上的伴生浮层：显示当前白板标题，按 **⌘⇧P** 读取当前选中的卡片，
在命令面板里对它们批量执行 `allume` CLI 命令。所有对 Allume 的操作都走
`/usr/local/bin/allume`，不截屏、不模拟点击；唯一模拟的按键是发给 Allume 的 ⌘C。

## 构建与运行

纯 Swift Package（SwiftUI + AppKit），不需要 Xcode 工程文件，需要 Xcode 命令行工具（Swift 5.9+，macOS 14+）。

```bash
scripts/run.sh          # swift build -c release → build/AllumeCompanion.app → 签名 → open
```

- `scripts/build-app.sh [debug|release]` 只构建打包，不启动。它把 `Resources/Info.plist`（含 `LSUIElement`）套在
  SwiftPM 产物外面做成 `.app`。
- 签名：优先用钥匙串里的 Apple Development / Developer ID 证书（可用 `CODESIGN_IDENTITY` 指定），
  找不到就 ad-hoc。**ad-hoc 签名每次重新构建都会让 macOS 丢掉辅助功能授权**，要重新勾选。
- 日志：`tail -f ~/Library/Logs/AllumeCompanion.log`。
- 测试钩子：`kill -USR1 $(pgrep -x AllumeCompanion)` 等于按 ⌘⇧P；`kill -USR2 ...` 等于点"排成 N 列"。
- 它是菜单栏常驻 app（无 Dock 图标），从菜单栏图标里退出。

## 需要的权限

| 权限 | 用途 | 没有会怎样 |
|---|---|---|
| 辅助功能（Accessibility） | 1) `AXObserver` 跟踪 Allume 窗口的位置、尺寸、激活状态，浮层才能贴上去；2) `CGEvent.postToPid` 向 Allume 发送 ⌘C | 浮层不显示，⌘⇧P 读不到选中 |
| Allume 的 CLI 读写模式 | `card-gather` / `card-move` / `delete` 都是写操作，CLI 默认只读 | 面板里显示 `exit 7`：`allume card-gather is unavailable: the CLI is in read-only mode`。在 Allume → Preferences → Command Line 里切到 read-write |

首次启动会弹系统提示；也可以从菜单栏图标 → "打开辅助功能设置…"。不需要"输入监控"：全局快捷键用的是
Carbon `RegisterEventHotKey`，不需要额外权限。

## 工作原理

### 当前白板

Allume 把最后浏览的文档 id 写在自己的 defaults 里：

```bash
defaults read com.musesoftware.museios-setapp lastViewedDocumentId
# 204d2cd29de354f8b3c1e157491a26ae:204d2cd29d7ea8528dcc6dd0f9c70381   (scope:id 形式的 qualified id)
```

导航后约 1–2 秒更新。Allume 是沙盒 app，`CFPreferencesCopyAppValue` 跨 app 读不到，所以直接每秒读
`~/Library/Containers/com.musesoftware.museios-setapp/Data/Library/Preferences/com.musesoftware.museios-setapp.plist`。

没有任何 CLI 命令能用白板 id 直接查标题（`card-content` 对白板 id 报 "No card"，`board-content` 只返回卡片），
所以启动后从 `list-workspaces` 的 `rootBoardId` 出发，用 `board-content <id> --kinds subBoard --format json`
BFS 爬一遍所有子白板，建 id → 标题表（79 个白板约 2.4 秒），遇到没见过的 id 再爬一次（最多 30 秒一次）。
收件箱用 `inboxId` / `personalInboxId` 对上。

### 选中的卡片（剪贴板旁路）

Allume 的卡片不在 Accessibility 树里（只有文字卡暴露为 AXTextArea），也没有选中相关的 API。
唯一可用的旁路：在 Allume 里按 ⌘C，它会为**每张**选中的卡片放一个 pasteboard item，类型
`com.allume.copyable.card`，内容是 JSON：

```json
{"cardPosition":[x,y],"scopeId":{"data":"<base64 16 字节>"},"docType":"board","cardId":{"data":"<base64 16 字节>"}}
```

`hex(scopeId) + ":" + hex(cardId)` 正好是 CLI 使用的卡片 qualified id（`scopeId` 是父白板前缀）。
同一次 ⌘C 还会放一个 `com.allume.copyable.selection` item（selectionId、cardInfos、chainInfos、selectionPath）
和每张卡的 `public.url` 分享链接，这些目前没用到。参考脚本：`~/.claude/skills/allume/scripts/selection.py`。

⌘⇧P 的流程（`SelectionReader.swift`）：

1. 把当前剪贴板的所有 item/类型/数据快照下来；
2. 用 `CGEvent.postToPid` 给 Allume 进程发 ⌘C（键码 8 + ⌘，一个按下一个抬起）；
3. 每 10ms 查 `NSPasteboard.general.changeCount`，最多等 300ms；没变就报"没有选中卡片 / 焦点不在画布"；
4. 解析所有 `com.allume.copyable.card` item（也接受 payload 形状相同的 `dyn.*` 类型，排除含 `cardInfos` 的 selection item）；
5. 把快照写回剪贴板，恢复用户原来复制的东西；
6. 打开命令面板，显示"选中 N 张卡"。

### 命令面板

命令通过 `Process` 调 `/usr/local/bin/allume`，stdout/stderr 原样显示在面板下半部分。

| 按钮 | 命令 |
|---|---|
| 排成 N 列（默认 3，Stepper 可调） | `allume card-gather --ids a,b,c --layout grid --columns N --x 80 --y 80 --spacing 40` |
| 统一尺寸 200×150 | 逐张 `allume card-move --id <id> --width 200 --height 150` |
| 删除…（面板内二次确认） | 逐张 `allume delete <id>`（软删除，可 `allume undelete <id>` 恢复） |

面板是 `NSPanel(.nonactivatingPanel)`，能接键盘（Esc 关闭、1/2/3 触发按钮）但不会把本 app 激活，
Allume 保持前台。浮层只在 Allume 是前台 app 且主窗口可见时显示。

## 脆弱点

- **剪贴板格式是 Allume 私有的**，`com.allume.copyable.card` 的类型名和 JSON 字段都没有文档，升级可能变。
  解析失败时面板会显示"⌘C 后剪贴板里没有 Allume 卡片"，可以用 `selection.py` 对照。
- **⌘C 依赖 Allume 的键盘焦点在画布上**。如果焦点在某张文字卡的编辑器里，⌘C 复制的是文字而不是卡片；
  如果没有选中任何东西，剪贴板不会变，300ms 后超时。
- **剪贴板会被短暂覆盖**：中间约 50ms 剪贴板里是 Allume 的卡片数据，之后恢复。恢复是按 item/类型逐个写回，
  对某些带 promise（延迟提供）的剪贴板内容可能恢复不完整。
- **Allume 的 ⌘C 会不会有副作用**（例如把卡片标记为"已复制"）未知，目前看没有。
- `lastViewedDocumentId` 是从 plist 文件读的，cfprefsd 落盘有延迟（实测 1–2 秒）；Allume 若改存储位置就失效。
- 白板标题靠爬 `board-content`，新建的白板要等下一次爬取（最多 30 秒）才有标题，之前只显示 id 尾巴。
- 浮层位置假设 Allume 主窗口顶部 52pt 是标题栏/工具栏，窗口全屏或分屏时没有特别处理。
- AX 坐标按主显示器左上角换算成 AppKit 坐标，多显示器下已考虑，但只跟踪 `AXFocusedWindow`（否则 `AXMainWindow`）。

## 代码结构

```
Package.swift                      SwiftPM executable，链接 Carbon
Resources/Info.plist               LSUIElement 等；build-app.sh 复制进 .app
scripts/build-app.sh, run.sh       构建、打包、签名、启动
Sources/AllumeCompanion/
  main.swift                       NSApplication 入口（.accessory）
  AppDelegate.swift                菜单栏项、权限申请、把各部件接起来
  AppState.swift                   ObservableObject：白板、选中、日志
  AllumeTracker.swift              AXObserver 跟踪 Allume 窗口（含 1s 兜底轮询）
  BoardWatcher.swift               读 lastViewedDocumentId + BFS 爬标题
  SelectionReader.swift            剪贴板快照 → ⌘C → 解析 → 恢复
  HotKey.swift                     Carbon 全局快捷键 ⌘⇧P
  AllumeCLI.swift                  Process 调 allume
  CommandRunner.swift              三条命令
  OverlayController.swift          两个 NSPanel（标题胶囊 + 命令面板）及定位
  Views.swift                      SwiftUI：PillView、CommandPanelView
  Log.swift                        ~/Library/Logs/AllumeCompanion.log
```
