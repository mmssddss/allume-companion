# Allume Companion

macOS 菜单栏 app，⌘K 时从 Allume 窗口顶部弹出的命令面板，所有操作走 `/usr/local/bin/allume` CLI。
读 docs/DEVELOPMENT.md 了解原理、权限和脆弱点（README.md / README.zh-CN.md 是给用户看的）；下面只记对改代码有用的事。

## 跑起来

- `scripts/run.sh`：构建 release、打包到 `build/AllumeCompanion.app`、签名、`open`。改完代码就跑它。
- 日志在 `~/Library/Logs/AllumeCompanion.log`（`Log.info`），不要指望 `log show` 能看到 NSLog。
- 需要辅助功能权限；用 Apple Development 证书签名后权限跨构建保留，ad-hoc 不保留。

## 硬性约束

- 不截屏、不模拟点击 Allume；只允许给 Allume 模拟两个按键：⌘C（读选中用）和跳白板后的一次 ⌘[（刷新面包屑，见下）。
  **只在 Allume 是前台 app 时发**（`SelectionReader.postCommand` 检查）：实测发给后台的 Allume，抬起丢了，它按按键重复
  速度（~29 次/秒）一直复制，用户的剪贴板被持续覆盖；补发抬起没用，把 Allume 切到前台再切走才停。查：剪贴板 changeCount
  3 秒涨 ~88 就是它，`kill -STOP` Allume 后归零。
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
- `allume open` 换了画布和窗口标题，但 Allume 左上角的面包屑不重画（停在上一块白板的路径）；Allume 里任何一次
  后退/前进（⌘[ / ⌘]，菜单里没有）都会按包含关系重画成正确路径。`open` 每次都压一条历史（同一 id 连开两次就有两条），
  所以 `openBoard` 连开两次再发 ⌘[：落在第二份上，画面不闪，只多一条指向同一白板的前进项。Allume 还没处理完第二次
  `open` 时 ⌘[ 会退到上一块白板（用户看到的是"跳到了错误的地方"，之后面包屑也乱），所以发完 ⌘[ 盯 0.6 秒窗口标题，
  变成别的白板就补一个 ⌘]（`stepForwardIfWentTooFar`，日志 `open board: ⌘[ went back to …`）。深链接 `allume://…` 试过几种都不导航。
  测跳转：`ALLUME_USR2=open:<白板文档id> open build/AllumeCompanion.app` 后 `kill -USR2`。
- 添加待办（`CommandRunner.addTodo`）：卡片无标题，正文一行 `@todo(due: YYYY-MM-DD) 内容`，和 `TodoIndex.context` /
  `dueDate` 读的格式一致；改格式两边一起改。`card-add` 建的文字卡按内容自动定尺寸（约 290×60）；卡片标题画在 `frame`
  上方约 25pt，不算进 frame。日期说法在 `DateWords`（规则表优先，`NSDataDetector` 兜底，它读的是真实时钟，不吃 `today` 参数）；
  `DateWords` + `TodoDraft` 是纯 Foundation，可以拼进一个 swiftc 脚本单测。视口靠 `BoardViewport` 用标题 `AXTextField` 拟合，缩放 1 时偏移 x≈窗口 x。
  测：`ALLUME_USR2="todo:内容 明天"` + `kill -USR2`；`ALLUME_USR2="type:交房租 下周"` 往面板输入框填字，配 `ALLUME_SNAPSHOT` 出图；面板快照 `ALLUME_PANEL_MODE=add`（快照分支要求同时设 `ALLUME_SELECT_IDS`）。
  `card-add` / `delete` 直接从终端跑也能写（不用 `open -W`），测完记得 `allume delete <卡片id>`。
- 当前白板模型（docs/DEVELOPMENT.md "当前白板模型"）：`BoardIndex` 用 `list-workspaces` → `board-content --kinds subBoard` BFS 建
  标题→文档 id 表（缓存在 `~/Library/Application Support/AllumeCompanion/boards.json`），`BoardModel` 用一次 `board-content`
  装入当前白板的卡片。⌘K 的 describeSelection 先查模型；撤销快照只在模型 2 秒内刷新过时用它，否则必须现查。
  后台调用用 `AllumeCLI.run(…, background: true)`，日志里是 `cli[bg]`；每次 ⌘K 打印一行"⌘K 统计"，前台应为 0。
  白板文档 id 的前缀等于它上面卡片 id 的 scope 前缀，可用来在同名白板间分辨。`open -W` 并发时偶发
  "Unable to block on applications"，`AllumeCLI.run` 统一重试一次。
- 删掉的白板：Allume 只软删挂它的卡片，白板文档还在，`allume open` 进得去但无处可回（面包屑、⌘[ 都失效）；`card-content`
  对那张卡照样返回、没有删除标记，只有 `board-content <父白板>` 和 `search` 不再列它。`BoardIndex`（boards.json）是白板搜索、
  最近去过、待办的唯一来源，不一致时先改它：`reconcile`（每次当前白板装入后，增/改名/挪动/卡片数/删）、`isDeleted` + `forget`
  （从列表跳转前 `openBoard(…, verify: true)`）。测：`ALLUME_USR2=open:<白板文档id>` 走的就是带 verify 的跳转。
- Allume 画布上能直接选到内嵌子白板里的卡片，窗口标题仍是父白板：`BoardModel` 除当前白板外还保留最近选中过的其他白板
  （`lookup` 跨白板找、`adopt` 收下回退路径读到的整块、`refreshOthers` 面板打开后在后台刷新它们）。
- ⌘K 的面板显示时间几乎全是 `setFrame(display: true)` 的重排，AX 查窗口只要 1–2 ms；所以关面板时就 `rearm`（清输入框、
  摆好位置），打开只剩 `orderFront`（5–15 ms）。日志行 `panel shown at …; setFrame X ms (relaid)` 出现
  "(relaid)" 说明这次重排了。离屏快照（`ALLUME_SNAPSHOT`）渲染不出 `glassEffect`，看玻璃效果只能在屏幕上看。
- 面板玻璃（macOS 26）是 `NSGlassEffectView` 外包一层圆角 `masksToBounds` 的视图：玻璃自带的软阴影会画到形状外面，
  被方形窗口边界截住后四角留下约 6% 的黑，看起来是灰色方底，窗口阴影也跟着变成方的。SwiftUI 的 `.glassEffect` 一样有这个问题。
  检查窗口的 alpha 和阴影形状：app 抓自己的窗口不需要屏幕录制权限，用 dlsym 调 `CGWindowListCreateImage`
  （`optionIncludingWindow` + `panel.windowNumber`；`boundsIgnoreFraming` 不含阴影），抓出来的图里玻璃背后的内容是空的。
- 剪贴板还原时每个 item 带 `org.nspasteboard.TransientType` + `AutoGeneratedType`（`SelectionReader.restoreMarkers`）。
  实测 Paste（`~/Library/Application Support/com.wiheads.paste-setapp/db.sqlite`，`sqlite3 -readonly` 查 `ZITEMENTITY`）：
  不加时每次 ⌘K 都刷新用户最后一条的时间戳，加了不动；Allume 的卡片数据只停 ~4ms（日志 `restored N ms after Allume wrote`），
  Paste 等剪贴板稳定才记，300ms 的闪烁都不记。Raycast 的库加密，没验证。
- 失效提示与诊断：剪贴板里有 `com.allume.copyable*` 却解析不出卡 → `Failure.unrecognized`，面板底栏报错；菜单栏 /
  设置 → Allume 的"复制诊断信息"（`Diagnostics.swift`，版本 + 设置 + 日志尾 80 行）。测过的 Allume 版本在
  `Diagnostics.testedAllume` 和两份 README，三处一起改。`Log.trim` 启动时把超过 4MB 的日志截到最后 1MB。
  测：`ALLUME_USR2=diagnostics` + `kill -USR2`（会覆盖剪贴板）。
- 第一次建 workspace-Companion 前弹确认框（`confirmCreatingRoot`）；测：`ALLUME_USR2=companion-consent ALLUME_SNAPSHOT=…`。
- `kill -USR1`（不预设选中时）会先把 Allume 切到前台再按 ⌘K，和真按一样。用户正在别的 app 里打字时 macOS 不让
  `activate` 抢前台（实测 `open -b`、AppleScript `activate` 都不生效），这时只能用预设选中的路径出图。
- 待办在列表里完成 / 推迟（⌘⏎ / ⌥⏎ / ⇧⌥⏎）：`OverlayPanel.sendEvent` 截带修饰键的回车（输入框里 ⌥⏎ 会插换行），
  `TodoIndex.replacingMarker` 只换第一行标记，`note-update` 写回（markdown 原样，frame 不变），撤销是写回旧正文。
  测：`ALLUME_USR2="todo-done:<卡片id>"` / `"todo-postpone:<卡片id>:<天数>"`；`postToPid` 给本 app 发的键在别的 app
  在前台时到不了面板，真按键只能手测。
- 面板位置在 `PanelPlacement`（纯几何，可 swiftc 单测）：全屏、分屏、窄窗口（最窄 420）、窗口一半在屏外、多屏。
  `ALLUME_FAKE_WINDOW=x,y,w,h` 假装 Allume 窗口的 frame。AX 读不到窗口位置时（实测 Allume 偶尔这样）`AllumeTracker`
  用 window server 的 bounds 兜底。
- 测试面板外观：`ALLUME_SELECT_IDS=… ALLUME_SNAPSHOT=/path.png open build/AllumeCompanion.app`，再 `kill -USR1`，
  面板会渲染成 PNG（`screencapture` 在这里没有屏幕录制权限）。加 `ALLUME_PANEL_MODE=todos|recent` 直接打开那张列表。
- 导航三件套（docs/DEVELOPMENT.md "导航"）：`VisitTrail`（trail.json）由 `BoardModel.onSwitched` 喂；`TodoIndex`（todos.json）在
  `BoardIndex.onCrawled` 之后扫全部白板（`--filter @todo --kinds text`，CLI 的 filter 接受 `@`，子串匹配所以 `@todo(due: …)` 也命中），
  到期日只认标记行 `@todo(due: YYYY-MM-DD)`，正文里散写的日期不算；当前白板由 `onLoaded` 用模型行
  免费更新；`DueReminders`（reminders.json）用 `UNUserNotificationCenter`，只在 .app 包里可用（裸可执行文件没有 bundle id 会崩，
  `available` 挡住）。通知权限只看 `authorizationStatus`（`DueReminders.isAllowed`）：实测 `authorizationStatus` 1（denied）而
  `alertSetting` 2（enabled）时 `add` 照样成功，但 usernoted 日志是 "Presenting … as none"、`notificationsAllowed: false`，
  什么都不显示（以前误以为这种组合算已允许）。查通知去没去屏幕：`/usr/bin/log stream --predicate 'eventMessage CONTAINS[c] "maverickli"'`
  （zsh 里 `log` 是内建命令，要写全路径）。`schedule` 每次现查，在系统设置里打开"允许通知"后下次扫描就生效。
  设置窗口"发一条测试通知"直接投一条并记日志（`ALLUME_USR2=test-notification` + `kill -USR2` 同效）。
  提醒开关和时间在 `ReminderSettings`（UserDefaults），触发时刻 = 到期日 + 设置的时分（`TodoIndex` 里的 9 点只是到期日本身）；
  改设置走 `DueReminders.reschedule`（先撤掉所有 `due-` 待发通知再排）。
- 安装检查（`AllumeInstall.swift`，docs/DEVELOPMENT.md "设置"）：`AllumeSetup.detect` 从 `/usr/local/bin/allume` 的链接目标往上找 `.app`，
  它的 bundle id 写进 `AllumeTracker.bundleID`（以前写死 Setapp 版的 `com.musesoftware.museios-setapp`，现在只是兜底）。
  写入模式没有查询命令、偏好文件也读不到，用 `card-move --id 000…:000…` 探测（只读 → "read-only mode"，可写 → "No card"），
  要 Allume 在运行。测：`ALLUME_FAKE_SETUP=noapp|nocli|readonly` 配 `ALLUME_SETTINGS_SNAPSHOT`。`/Applications/Muse.app` 在本机是
  别的 app（`com.meta.endo`），不能按名字认。
- 设置窗口（`Settings.swift`，菜单栏 → 设置… ⌘,）：`NSTabViewController`（`.toolbar` + `toolbarStyle = .preference`）
  每页一个 `NSHostingController`，`sizingOptions = .intrinsicContentSize`（设成 `[]` 时 `fittingSize` 是 0，窗口塌成 0 高、
  截图也抓不到），切页时 `fitWindow` 按 `fittingSize` 改窗口高度、顶边不动。`SettingsModel` 的数据窗口开着时每秒 `refresh`；模型在
  `registerDefaults` 之前就建好了，所以提醒设置只在 `refresh` 里读。登录项用 `SMAppService.mainApp`（没在本机点过开关）。
  出图：`ALLUME_SETTINGS_SNAPSHOT=/path.png open build/AllumeCompanion.app`（用 `OverlayController.capturePNG` 抓自己的窗口）。
  面板模式在 `AppState.panelMode`，Esc 在列表里是返回不是关闭。
- 面板列表（docs/DEVELOPMENT.md "命令面板"）：窗口只有一个尺寸（`PanelMetrics.maxHeight`，列表区固定 8 行高，像 Raycast），打开后
  不再改大小、不跳；凡是自己变的都淡入淡出（时长在 `PanelMetrics`）：窗口开关（`showPanel` / `hidePanel` 的 alpha，
  关的途中再 ⌘K 会取消）、⌘C 有结果后各行（AppDelegate 在 `withAnimation` 里把 `selectionPending` 置假；置真和清空选中
  用 `disablesAnimations`，免得在淡入的窗口上淡出旧内容）、输入框左边的图标、右端的选中小卡片、
  手画的提示文字、小卡片后到的缩略图。打字筛选和 ↑↓ 是用户自己的操作，不加动画。
  版式（仿 Raycast）的尺寸都在 `PanelMetrics`（`inset` 左边线、`icon` + `iconGap` 让输入框的字和行标题对齐）。
  文字用 `Theme.text1/2/3`（label 色的固定不透明度），不用 `.secondary`/`.tertiary`：玻璃里的离屏快照中它们画得和
  标题几乎一样黑，带颜色的字也丢色（屏幕上未逐一核对）；固定不透明度在快照和屏幕上一致。要强调就用填色小标签或彩色图标。
  列表是一个普通 VStack 里的一个 ForEach（`listItems` 把组标题和行摊平），行的 id 带上所在组的 id：以前用 LazyVStack +
  组内 ForEach 只按行 id 区分，行从一组挪到另一组（空输入 → 打字）时会留着旧视图，高亮不更新，但 ⏎ 照常执行。
  空输入按 `CommandGroup` 分组、按 `CommandSpec.needs` 过滤（没选中 / 一张 / 多张 / 一张子白板）；打字时是命令、
  白板（`AppState.boards` ← `BoardIndex.refs`）、待办三组按最好匹配排序。
  测各场景：`ALLUME_SELECT_IDS=","`（空选中）/ 一张子白板 id / 多张 id，配 `ALLUME_SNAPSHOT`；打字用 `ALLUME_USR2="type:…"`。
  测打开过程：`ALLUME_FRAMES=<目录> open build/AllumeCompanion.app` 后真按 ⌘K（或 `kill -USR1`），每次打开在
  `<目录>/show-<时间>/` 下每 ~25ms 抓一帧窗口（文件名带 ms 时间和窗口 alpha；图里不含 alpha 和玻璃背后的内容）。
- 日记与项目（`Companion.swift`，docs/DEVELOPMENT.md "日记与项目"）：自己的白板 id 全记在 `companion.json`（按 workspace），只在
  `workspace-Companion` 这棵树里写；改项目状态只认 Todo / Doing / Done 上 `project-` 开头的子白板（现读确认）。
  "挪"卡片 = `card-create --document <白板id>` 挂到目标 + `delete` 原卡，白板内容不丢（实测）。子白板卡默认 200×150、最小约
  120×100；文字卡最小 170×40（再小会被夹回）。`board-create -f id` 只打印 id；`card-create -f json` 输出一行数组。
  "记到某天"（`addTodoToDay`）复用添加待办的输入解析，`ensureDay` 和"今天"共用；贴完用 `onBoardRead` 喂 `TodoIndex.adopt`、
  `BoardIndex.noteCardCount` 改卡片数（否则 cardCount 0 的日白板在下次爬表前会被扫描跳过，待办又消失）。
  测：`ALLUME_USR2="day:内容 明天"` + `kill -USR2`（测完 `allume delete`）；面板 `ALLUME_PANEL_MODE=day`。
  测：`ALLUME_USR2="今天"`（`昨天` `明天` `本月` 同理）/ `"project:名字"` / `"完成"`（配 `ALLUME_SELECT_IDS`）+ `kill -USR2`，撤销 `kill -INFO`；
  `ALLUME_PANEL_MODE=project` 出新建项目输入框；设置页 `ALLUME_SETTINGS_TAB=companion`。删掉 companion.json 不会重复建
  （会按标题在父白板上认回来），但 `filledMonths` 丢了会把每个月重读一遍。
- 界面语言（docs/DEVELOPMENT.md "构建与运行"）：中英两套，跟随系统语言，不加别的语言。代码里的中文原文就是键：`String(localized: "…")`，
  以及 SwiftUI `Text("…")` / `Button("…")` 的字面量（`LocalizedStringKey`，默认查 main bundle）；把 `String` 变量交给 `Text`
  不会翻译，所以 Settings 的 `checkbox` / `labeled` / `note` / `statusRow` 参数是 `LocalizedStringKey`，运行时拼好的字用 `note(verbatim:)`。
  表在 `Resources/Localizable.xcstrings`（sourceLanguage zh-Hans），build-app.sh 用 `xcrun xcstringstool compile` 编进
  `Contents/Resources/{en,zh-Hans}.lproj`。不走 SwiftPM resources / `Bundle.module`：`swift build` 只把 .xcstrings 原样拷进 bundle、
  不编译（实测），而且 SwiftUI 字面量默认查 main bundle。zh-Hans 也必须有 `.strings` 和 `.stringsdict` 两张表：某语言缺一张时
  查找落到开发区域（Info.plist `CFBundleDevelopmentRegion` = en）那张，中文界面会冒英文（实测：复数串变成 "1 cards"）。所以
  复数键在目录里带一个 zh-Hans 的 plural `other`（就是原文），`section.*` 键带 zh-Hans 值；build-app.sh 缺表就失败。
  改了界面文字跑 `scripts/sync-strings.sh`：带 `-emit-localized-strings` 编译抽出所有键 → `xcstringstool sync`，列出还没英文的键
  和代码里不再有的（stale，可删）；英文直接改 JSON 或用 Xcode 打开 .xcstrings，英文复数用 plural variations（one / other）。
  同一个中文词要两种英文时用独立键 `String(localized: "section.commands", defaultValue: "命令")`（分组标题 Commands，行尾标签 Command）。
  星期标签 `DateWords.weekdayLabel` 是运行时键（周一…周日，目录里 manual），只用于显示；写进 Allume 的东西不翻译：日 / 月白板标题、
  `@todo(due: …)`、`DateWords` 规则表（解析用）。例外是月白板的星期表头卡（`CompanionLayout.weekdayNames(_:)`，
  一 … 日 / Mon … Sun，写死在代码里、不走字符串表）：跟 `boardLanguage` 走，语言变了在 Allume 运行起来时由
  `relabelWeekdaysIfNeeded` 用 `note-update --document-id <卡片的 document.id>` 原地改写全部月白板（实测文字卡可用，frame 不变），
  已写的语言记在 UserDefaults `companion.headerLanguage`（缺省 zh）。`Log.info` 和测试钩子不翻译。
  英文日期输入靠 `NSDataDetector`：`tomorrow` `Friday` `in 3 days` `Oct 20` `10-20` 能认，`next week` `end of month` 不认，
  `next tuesday` 算成下下周二（所以提示文案不用它）。测英文：`open -n build/AllumeCompanion.app --args -AppleLanguages '(en)'`，
  配上面的 `ALLUME_SNAPSHOT` / `ALLUME_SETTINGS_SNAPSHOT`；本机已经开着一份时 `-n` 另起一个，测完按 pid 杀掉自己那个。
- 演示视频（docs/DEVELOPMENT.md "演示视频"）：`scripts/make-demo-board.py` 建 Demo 白板，`ALLUME_DEMO_ROOT=<id>` 让面板只显示
  Demo 里的白板 / 待办 / 最近去过（`Demo.swift`，日记和项目建在 Demo 上，用 `*-demo.json`，不排提醒）；
  `scripts/reset-demo-board.py` 每段开拍前复位（会改 `companion-demo.json`，Companion 要重启）；`build/record-region`
  （`scripts/record-region.swift`，ScreenCaptureKit，ProRes、无指针、约 57fps）录，`scripts/make-demo-media.sh` 转
  mp4 / webm / jpg / gif 和 `MASTER_DIR` 下的恒定 60fps 母版。录完 `ALLUME_DEMO_ROOT` 不设，正常启动。
- 无 Xcode 工程；SwiftPM + 手写 Info.plist 足够。Swift 6.3 编译器、语言模式 5。
- 图标：`Resources/AppIcon.icon`（Icon Composer 格式）由 build-app.sh 里的 `xcrun actool … --app-icon AppIcon` 编成
  Assets.car + AppIcon.icns。`icon.json` 的 `groups` **第一个在最上层**（和 Icon Composer 界面一致）。想看系统真正渲染的
  玻璃版：构建后用 `NSWorkspace.shared.icon(forFile: "build/AllumeCompanion.app")` 画到 PNG（`qlmanage -t` 对 .app 会卡死，
  临时拼的假 .app 也渲染不出来）；icns 兜底只含 16/32/128/256 四档。改几何只改 `scripts/make-icon-assets.py` 再跑它。
