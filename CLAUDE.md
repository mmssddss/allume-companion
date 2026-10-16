# Allume Companion

macOS 菜单栏 app，⌘K 时从 Allume 窗口顶部弹出的命令面板，所有操作走 `/usr/local/bin/allume` CLI。
读 README.md 了解原理、权限和脆弱点；下面只记对改代码有用的事。

## 跑起来

- `scripts/run.sh`：构建 release、打包到 `build/AllumeCompanion.app`、签名、`open`。改完代码就跑它。
- 日志在 `~/Library/Logs/AllumeCompanion.log`（`Log.info`），不要指望 `log show` 能看到 NSLog。
- 需要辅助功能权限；用 Apple Development 证书签名后权限跨构建保留，ad-hoc 不保留。

## 硬性约束

- 不截屏、不模拟点击 Allume；唯一允许模拟的按键是发给 Allume 的 ⌘C（读选中用）。
- 对 Allume 的所有读写都通过 CLI（`AllumeCLI.run`），命令和输出要显示在面板日志里。
- 面板窗口必须是 `.nonactivatingPanel`，不能抢 Allume 的前台。

## 已知事实（实测）

- Allume 的容器和 group container 对伴生 app 及其子进程都不可读（按 responsible process 判定），所以
  `lastViewedDocumentId` 读不到；当前白板标题取 Allume 窗口的 AX 标题。
- CLI 自己是沙盒 app，直接 `Process` 启动时读不到 `isCLIReadOnly` → 一律只读（exit 7）；必须经 `open -W` 启动。
- `allume search` 不接受空 query；`allume card-content <白板id>` 报 "No card"。
- `board-content` / `card-content` 的 `createdAt` 是调用时间，不是创建时间；创建先后用卡片 id 后半段的字典序（单调递增）。
- Allume 的 AX 树（`ALLUME_AXDUMP=1` + `kill -USR2` 导出，Allume 是 Catalyst app，根是 `AXGroup/iOSContentGroup`）实测：
  - 每张卡是一个 `AXGroup`，标题是里面 `AXTextField` 的 value（subBoard 也有；没标题的图片卡是 12×21 的空字段），
    image/pdf 的内容区是空值的 `AXStaticText`，文字卡/文字链是带完整正文的 `AXTextArea`。子白板缩略图里每张小卡一个空 `AXStaticText`。
  - 节点坐标是屏幕坐标，和 CLI `frame` 线性对应（屏幕 = 白板 × 缩放 + 偏移；缩放 1 时偏移只在 y 上，约 73–78pt）。
    拿任一张卡的两套坐标就能解出缩放和偏移，于是可以算出视口在白板上的范围和哪些卡可见。
  - 屏幕外的卡仍在树里（拖出窗口后 x=2032 的卡照样有节点），树是整块白板不是视口，解偏移不需要先找屏幕上的卡。
  - **没有选中状态**：真选中一张卡后所有节点 `AXSelected` 仍是 false，卡片组的 `AXSelectedChildren` 读出 kAXErrorNoValue（-25212），
    `AXFocusedUIElement` 仍是整个内容组。选中仍靠 ⌘C + 剪贴板。
  - 编辑文字卡时 `AXFocusedUIElement` 就是那张卡的 `AXTextArea`：正文、屏幕坐标、`AXSelectedTextRange`（光标/选中区间）都有，
    所以"正在改哪张卡"和"笔记里选中的那段字"拿得到；卡片 id 树里没有，要用正文比对 `BoardModel` 或坐标换算回 `frame` 反查。
  - 窗口的 `AXDocument` 读出来是空的，白板文档 id 拿不到；手写笔迹没有。
- CLI 做的移动在 Allume 里 ⌘Z 撤不掉（不经过它的 undo manager），只能 `card-move` 恢复；面板的"撤销"就是这么做的。
  面板不提供删除：Allume 自己的 Delete 键带原生 ⌘Z。
- `board-content` 只接受完整白板文档 id `<前缀>:<后缀>`，卡片 id 的 scope 前缀不够；`card-content <卡片id> -f json` 的
  `parentDocumentId` 给出父白板文档 id，`frame` 给出位置尺寸。`card-move` 接受小数坐标；`undelete` 会把卡片放回原 frame。
- 缩略图字节只能从 CLI 的 stdout 拿（CLI 是沙盒 app，`-o` 写不到任意路径）：image 用 `card-content <id> --contents raw -f json`
  （字节在 stdout、元数据在 stderr），pdf 用 `card-pdf-page <id> --page 1 --max-dimension 256 -f json`（最小 256）；
  `AllumeCLI.run(…, raw: true)` 返回 `stdoutData`。`board-content -f json` 的行里已带 text/chain 的 `document.body`
  和 subBoard 的 `document.id`，不必再逐张 `card-content`。
- 子白板缩略图由 `BoardThumbnailRenderer` 用 `board-content` 行离屏画出（240×180，文字卡 2–3pt 小字、image/pdf 真图最多 6 张、
  嵌套白板灰块），按白板文档 id 缓存在 `~/Library/Application Support/AllumeCompanion/thumbs/<id>.png` + `<id>.hash`
  （行里影响画面的字段的 SHA-256；相同就不重画。不能哈希整段 JSON：`createdAt` 每次调用都等于调用时间）。`rm -rf` 那个目录即可强制重画。板上没有墨迹数据（只有 `inkStrokeCount`），画不了笔画。
- 当前白板模型（README "当前白板模型"）：`BoardIndex` 用 `list-workspaces` → `board-content --kinds subBoard` BFS 建
  标题→文档 id 表（缓存在 `~/Library/Application Support/AllumeCompanion/boards.json`），`BoardModel` 用一次 `board-content`
  装入当前白板的卡片。⌘K 的 describeSelection 先查模型；撤销快照只在模型 2 秒内刷新过时用它，否则必须现查。
  后台调用用 `AllumeCLI.run(…, background: true)`，日志里是 `cli[bg]`；每次 ⌘K 打印一行"⌘K 统计"，前台应为 0。
  白板文档 id 的前缀等于它上面卡片 id 的 scope 前缀，可用来在同名白板间分辨。`open -W` 并发时偶发
  "Unable to block on applications"，`AllumeCLI.run` 统一重试一次。
- Allume 画布上能直接选到内嵌子白板里的卡片，窗口标题仍是父白板：`BoardModel` 除当前白板外还保留最近选中过的其他白板
  （`lookup` 跨白板找、`adopt` 收下回退路径读到的整块、`refreshOthers` 面板打开后在后台刷新它们）。
- ⌘K 的面板显示时间几乎全是 `setFrame(display: true)` 的重排，AX 查窗口只要 1–2 ms；所以关面板时就 `rearm`（清输入框、
  恢复全部命令、摆好尺寸），打开只剩 `orderFront`（5–15 ms）。日志行 `panel shown at …; setFrame X ms (relaid)` 出现
  "(relaid)" 说明这次重排了。离屏快照（`ALLUME_SNAPSHOT`）渲染不出 `glassEffect`，看玻璃效果只能在屏幕上看。
- 测试面板外观：`ALLUME_SELECT_IDS=… ALLUME_SNAPSHOT=/path.png open build/AllumeCompanion.app`，再 `kill -USR1`，
  面板会渲染成 PNG（`screencapture` 在这里没有屏幕录制权限）。
- 无 Xcode 工程；SwiftPM + 手写 Info.plist 足够。Swift 6.3 编译器、语言模式 5。
- 图标：`Resources/AppIcon.icon`（Icon Composer 格式）由 build-app.sh 里的 `xcrun actool … --app-icon AppIcon` 编成
  Assets.car + AppIcon.icns。`icon.json` 的 `groups` **第一个在最上层**（和 Icon Composer 界面一致）。想看系统真正渲染的
  玻璃版：构建后用 `NSWorkspace.shared.icon(forFile: "build/AllumeCompanion.app")` 画到 PNG（`qlmanage -t` 对 .app 会卡死，
  临时拼的假 .app 也渲染不出来）；icns 兜底只含 16/32/128/256 四档。改几何只改 `scripts/make-icon-assets.py` 再跑它。
