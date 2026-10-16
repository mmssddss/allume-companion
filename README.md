# Allume Companion

Allume（原 Muse）白板的伴生命令面板：在 Allume 里按 **⌘K**，它读取当前选中的卡片，从 Allume 窗口顶部弹出面板，
对这些卡片批量执行 `allume` CLI 命令；Esc、再按一次 ⌘K、点回 Allume 或切走 Allume 都会收起。平时不显示任何东西。所有对 Allume 的操作都走
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
- 测试钩子：`kill -USR1 $(pgrep -x AllumeCompanion)` 等于按 ⌘K；`kill -USR2 ...` 等于点"排成 N 列"
  （启动时设 `ALLUME_USR2=resize` 可改成"统一尺寸"）；`kill -INFO ...` 等于点"撤销"；
  `ALLUME_SELECT_IDS=a,b,c open build/AllumeCompanion.app` 启动时直接预设选中的卡片 id，不经过 ⌘C；
  用 `ALLUME_AXDUMP=1 open build/AllumeCompanion.app` 启动后，`kill -USR2` 改为把 Allume 窗口的 Accessibility 树写进日志。
- 它是菜单栏常驻 app（无 Dock 图标），从菜单栏图标里退出。

## 需要的权限

| 权限 | 用途 | 没有会怎样 |
|---|---|---|
| 辅助功能（Accessibility） | 1) `AXObserver` 跟踪 Allume 窗口的位置、尺寸、激活状态，面板才能贴在窗口顶部；2) `CGEvent.postToPid` 向 Allume 发送 ⌘C | 面板不出现，⌘K 读不到选中 |
| Allume → Preferences → Command Line 里的读写模式 | `card-gather` / `card-move` 都是写操作 | 面板里显示 `allume card-gather is unavailable: the CLI is in read-only mode`。如果设置里已经是 read-write 还报这个，见下面"CLI 为什么要用 open 启动" |

首次启动会弹系统提示；也可以从菜单栏图标 → "打开辅助功能设置…"。不需要"输入监控"：全局快捷键用的是
Carbon `RegisterEventHotKey`，不需要额外权限。注册了的全局快捷键会在所有 app 里吞掉这个按键，
所以 ⌘K 只在 Allume 是前台 app（或命令面板是 key window）时注册，切到别的 app 就注销，别的 app 的 ⌘K 不受影响。

## 工作原理

### 当前白板

Allume 主窗口的 Accessibility 标题（`kAXTitleAttribute`）就是当前白板的名字（例如 "Project"），
`AllumeTracker` 在跟踪窗口位置的同时顺手读出来，订阅了 `kAXTitleChangedNotification`，导航后立即更新。

走过的弯路（都在另一个进程里能用，在伴生 app 里不能用，原因见下面"CLI 为什么要用 open 启动"）：

- `defaults read com.musesoftware.museios-setapp lastViewedDocumentId` 给出当前白板的 qualified id，
  但 Allume 是沙盒 app，它的容器 `~/Library/Containers/com.musesoftware.museios-setapp/` 受
  macOS 保护，伴生 app（以及它启动的 `defaults`、`plutil`）读到的是 "you don't have permission" / "Domain not found"。
  在终端里能读，是因为终端的 responsible process（Claude / Terminal）被授予了完全磁盘访问之类的权限。
- 没有 CLI 命令能用白板 id 直接查标题（`card-content <白板id>` 报 "No card"，`search` 不接受空 query）；
  能做的是从 `list-workspaces` 的 `rootBoardId` 用 `board-content --kinds subBoard` BFS 爬全部子白板
  （79 个白板约 2.4 秒）。现在不需要了。

### CLI 为什么要用 `open` 启动

`/usr/local/bin/allume` 是 `Allume.app/Contents/MacOS/allume-cli` 的符号链接，这个 CLI **自己也是沙盒 app**
（entitlements 里有 `com.apple.security.app-sandbox` 和 app group `group.T68Z94627S.com.musesoftware.museios-setapp`）。
它在连接 Allume 之前先读 app group 偏好里的 `isCLIReadOnly`（文件在
`~/Library/Group Containers/group.T68Z94627S.com.musesoftware.museios-setapp/Library/Preferences/`），读不到就按只读处理。

macOS 对 group container 的访问按 **responsible process** 判定：伴生 app 用 `Process` 直接启动 CLI 时，
responsible process 是伴生 app，读取被拒，于是所有写命令都报
`allume card-gather is unavailable: the CLI is in read-only mode`（exit 7），哪怕 Preferences 里已经是 read-write。

解决：`AllumeCLI` 用 `open -W -n --stdout <f> --stderr <f> -a <allume-cli> --args …` 经 LaunchServices 启动 CLI，
CLI 成为自己的 responsible process，靠自己的 entitlement 读 group container，写命令就通了。
代价是每次调用约 150ms（直接 `Process` 约 30ms），而且 `open` 不转发 CLI 的退出码，所以 stderr 里出现 `error` 就当失败。

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

⌘K 的流程（`SelectionReader.swift`）：

1. 把当前剪贴板的所有 item/类型/数据快照下来；
2. 用 `CGEvent.postToPid` 给 Allume 进程发 ⌘C（键码 8 + ⌘，一个按下一个抬起）；
3. 每 10ms 查 `NSPasteboard.general.changeCount`，最多等 300ms；没变就报"没有选中卡片 / 焦点不在画布"；
4. 解析所有 `com.allume.copyable.card` item（也接受 payload 形状相同的 `dyn.*` 类型，排除含 `cardInfos` 的 selection item）；
5. 把快照写回剪贴板，恢复用户原来复制的东西；
6. 打开命令面板，显示"选中 N 张卡"。

### 命令面板

命令经 `open -W` 调 `/usr/local/bin/allume`（原因见上），面板只显示一行结果（成功时"已排成 3 列"，失败时 stderr 第一行），
完整的命令与输出写进 `~/Library/Logs/AllumeCompanion.log`。

| 按钮 | 命令 |
|---|---|
| 排成 N 列（默认 3，Stepper 可调） | `allume card-gather --ids a,b,c --layout grid --columns N --x 80 --y 80 --spacing 40` |
| 统一尺寸 200×150 | 逐张 `allume card-move --id <id> --width 200 --height 150` |
| 撤销：<上一步> | 见下面"撤销上一步" |

按键 1/2/3 分别对应三个按钮。不提供删除：Allume 自己的 Delete 键就是删除，而且带原生 ⌘Z。
面板是 `NSPanel(.nonactivatingPanel)`，能接键盘（Esc 关闭、1/2/3 触发按钮）但不会把本 app 激活，
Allume 保持前台。面板只在 ⌘K 之后出现，贴在 Allume 主窗口顶部居中，跟随窗口移动；Allume 不在前台就收起。
面板头部显示当前白板名（来自 Allume 的窗口标题）。

### 撤销上一步

**为什么 Allume 自己的 ⌘Z 不管用**：CLI 的移动走的是 Allume 的 helper 管道（CLI 进程 → app 内的命令处理器
→ 直接改文档），不经过界面层的 undo manager，所以在 Allume 里按 ⌘Z 撤不掉 CLI 做的事（实测）。
只能用 CLI 自己把状态改回去：`allume card-move`（如果用 CLI 删过卡，`allume undelete <id>` 能恢复）。

于是 `CommandRunner` 在每条命令执行前先记下恢复所需的状态，面板上多一个"撤销：<上一步名字>"按钮（按键 3）：

| 命令 | 执行前记录 | 撤销 = |
|---|---|---|
| 排成 N 列 / 统一尺寸 | 每张卡当前的 frame（x,y,w,h） | 逐张 `allume card-move --id … --x … --y … --width … --height …` 回到原值 |

frame 怎么读：`allume board-content <白板文档id> --format json` 一次给出整块白板上所有卡片的 `frame`。
白板文档 id 不能从卡片 id 推出来——卡片 id `<scope>:<card>` 的 `scope` 等于父白板文档 id 的前缀，但后缀不同，
而 `board-content` 只接受完整的 `<前缀>:<后缀>`（只给前缀报 "Invalid board id"，`<scope>:<scope>` 报 "No board"）。
所以先对该白板的第一张选中卡跑一次 `allume card-content <卡片id> --format json`，它的 `parentDocumentId` 就是白板文档 id
（按 scope 缓存在内存里，同一白板之后只需一次 `board-content`）。白板列表里没出现的卡片（例如选中跨多块白板）逐张
用 `card-content` 补读；读不到 frame 的卡片会在日志里警告，撤销时不会恢复它们。

局限：

- **只有一层**：只记最近一步，新命令覆盖旧记录，撤销本身不可撤销；记录在内存里，app 重启就没了。
- 只恢复 frame 和存在性。卡片 zOrder、text chain 的尺寸（`card-move` 对 chain 忽略 `--width/--height`）、
  `card-gather` 可能改动的其他属性都不在记录范围内。
- 记录是在命令**之前**读的；如果用户在命令和撤销之间手动动过这些卡片，撤销会把手动改动也盖掉。
- 多出两次 CLI 调用（`card-content` + `board-content`，各约 150ms），面板日志只显示命令行和"已记录 N/M 张"，不显示 JSON。

## 脆弱点

- **剪贴板格式是 Allume 私有的**，`com.allume.copyable.card` 的类型名和 JSON 字段都没有文档，升级可能变。
  解析失败时面板会显示"⌘C 后剪贴板里没有 Allume 卡片"，可以用 `selection.py` 对照。
- **⌘C 依赖 Allume 的键盘焦点在画布上**。如果焦点在某张文字卡的编辑器里，⌘C 复制的是文字而不是卡片；
  如果没有选中任何东西，剪贴板不会变，300ms 后超时。
- **剪贴板会被短暂覆盖**：中间约 50ms 剪贴板里是 Allume 的卡片数据，之后恢复。恢复是按 item/类型逐个写回，
  对某些带 promise（延迟提供）的剪贴板内容可能恢复不完整。
- **Allume 的 ⌘C 会不会有副作用**（例如把卡片标记为"已复制"）未知，目前看没有。
- 白板标题来自 Allume 的窗口标题，只有名字没有 id；Allume 若改成固定窗口标题就失效。
- CLI 经 `open` 启动依赖 `open` 的 `--stdout/--stderr/-W` 行为，退出码靠 stderr 猜。
- 面板位置假设 Allume 主窗口顶部 52pt 是标题栏/工具栏，窗口全屏或分屏时没有特别处理。
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
  AllumeTracker.swift              AXObserver 跟踪 Allume 窗口位置/激活/标题（含 1s 兜底轮询）
  AXDump.swift                     调试：把 Allume 的 AX 树写进日志
  SelectionReader.swift            剪贴板快照 → ⌘C → 解析 → 恢复
  HotKey.swift                     Carbon 全局快捷键 ⌘K（只在 Allume 前台时注册）
  AllumeCLI.swift                  经 open -W 调 allume（原因见上）
  CommandRunner.swift              三条命令 + 一层撤销（执行前记 id / frame）
  OverlayController.swift          命令面板 NSPanel 及定位
  Views.swift                      SwiftUI：CommandPanelView
  Log.swift                        ~/Library/Logs/AllumeCompanion.log
```
