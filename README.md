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
- 测试钩子：`kill -USR1 $(pgrep -x AllumeCompanion)` 等于按 ⌘K（预设选中时也会重新从模型/CLI 补标题并打印 ⌘K 统计）；`kill -USR2 ...` 等于点"排成 N 列"
  （`ALLUME_USR2="小"` 这类值会像在输入框里打字一样经过命令匹配）；`kill -INFO ...` 等于点"撤销"；
  `ALLUME_SELECT_IDS=a,b,c open build/AllumeCompanion.app` 启动时直接预设选中的卡片 id，不经过 ⌘C
  （这时 `kill -USR1` 只开关面板、不重读选中；再加 `ALLUME_SNAPSHOT=/path.png` 会在面板打开时把它渲染成 PNG，
  不需要屏幕录制权限）；
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
  （79 个白板约 2.4 秒）。现在就是这么做的，见下面"当前白板模型"。

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

⌘K 的流程（`AppDelegate.readSelectionAndShow` + `SelectionReader.swift`）。面板先弹出（实测 13–47ms，第一次略慢是 SwiftUI 首次布局），
高度按"全部命令"预先算好，不等剪贴板；剪贴板这一轮在后面跑完再填进卡片层叠，没选中时 300ms 超时也只是层叠不出现：

1. 把当前剪贴板的所有 item/类型/数据快照下来；
2. 用 `CGEvent.postToPid` 给 Allume 进程发 ⌘C（键码 8 + ⌘，一个按下一个抬起）；
3. 每 2ms 查 `NSPasteboard.general.changeCount`，最多等 300ms（有选中时实测 40–70ms 就变）；没变就只写日志；
4. 解析所有 `com.allume.copyable.card` item（也接受 payload 形状相同的 `dyn.*` 类型，排除含 `cardInfos` 的 selection item）；
5. 把快照写回剪贴板，恢复用户原来复制的东西；
6. 打开命令面板，显示"选中 N 张卡"。

### 命令面板（Spotlight 风格）

⌘K 之后面板从 Allume 窗口顶部弹出：左边是选中卡片的层叠缩略（最多叠 3 张，角标是张数，标题、类型和缩略图
在面板打开后异步补上，见下面"卡片缩略图从哪来"），右边是命令输入框，下面列出匹配的命令。↑↓ 选，⏎ 执行，Esc 或再按 ⌘K 关闭。
执行后面板不关，底部一行显示结果（成功如"已排成 3 列"，失败是 stderr 第一行），可以接着输 `撤销`。

命令和别名都在 `CommandCatalog.swift`，匹配规则：按空格和中英文边界分词，每个词要能匹配某个别名
（完全相等 > 前缀 > 包含 > 子序列，同分时以最后一个词为准），数字会被抽出来当列数。
尺寸只有小 / 中 / 大三档（4:3，中是 Allume 的默认卡片大小），没有自由输入宽高：

| 输入示例 | 命令 | CLI |
|---|---|---|
| `排成4列`、`grid 4`、`sort`、`pailie` | 排成 N 列（默认 3） | `allume card-gather --ids … --layout grid --columns N --x <选中最小 x> --y <最小 y> --spacing 40`，ids 按先 y 后 x 的阅读顺序，网格锚在选中区域左上角 |
| `一行`、`row`、`横排` | 排成一行 | `card-gather --layout row …` |
| `一列`、`column`、`竖排` | 排成一列 | `card-gather --layout column …` |
| `统一`、`大小`、`size`、`中` | 统一大小：中（200×150，Allume 默认） | 逐张 `allume card-move --id <id> --width 200 --height 150` |
| `小`、`缩小`、`small` | 统一大小：小（160×120） | 同上，160×120 |
| `大`、`放大`、`big` | 统一大小：大（280×210） | 同上，280×210 |
| `撤销`、`undo`、`chexiao` | 撤销上一步 | 见下面 |

排列类命令可以带顺序修饰词，单独输修饰词时作用于默认的"排成 3 列"：

| 修饰词 | 效果 |
|---|---|
| （不写）、`顺序`、`asc` | 阅读顺序：先 y 后 x，卡片保持原来的视觉顺序 |
| `逆序`、`倒序`、`reverse`、`desc` | 上述顺序反过来 |
| `按标题`、`标题`、`名字`、`title`、`by name` | 按标题排（`localizedStandardCompare`，跟随系统语言的排序规则；中文系统下汉字标题排在拉丁字母前，数字按数值） |
| `按时间`、`时间`、`date`、`created` | 按创建先后从旧到新。`board-content` 的 `createdAt` 实测等于调用时间，不能用；卡片 id 冒号后的部分带单调递增的时间前缀（HLC 风格），按它排 |

例：`一行逆序`、`排成4列倒序`、`按标题一列`、`grid 2 by title`、`按时间逆序`。
修饰词会从中文连写里剥出来（"列倒序" → 列 + 倒序），剩下的词再去匹配命令。

输入为空时列出全部命令。没有选中卡片时只剩"撤销"。完整的命令与输出写进 `~/Library/Logs/AllumeCompanion.log`。

面板是 `NSPanel(.nonactivatingPanel)`，能接键盘但不会把本 app 激活，Allume 保持前台。不提供删除：
Allume 自己的 Delete 键就是删除，而且带原生 ⌘Z。

### 当前白板模型：什么时候查 CLI、什么时候用缓存

Allume 没有任何变更通知，容器也读不到，所以伴生 app 自己在内存里维护一份"当前白板"的副本，⌘K 时基本不查 CLI。
两层：

**BoardIndex（标题 → 白板文档 id）**。窗口标题只给名字，`board-content` 要的是完整文档 id，这张表把两者连起来。
启动时先读缓存 `~/Library/Application Support/AllumeCompanion/boards.json`，然后在后台重新爬一遍：
`list-workspaces` 拿每个 workspace 的 `rootBoardId`（标题记为 workspace 名），再对每块白板
`board-content <id> --kinds subBoard --format json` BFS（`document.id` 是子白板的文档 id，4 个并发，79 块白板约 8 秒，
`open -W` 偶发 "Unable to block on applications" 时重试一次）。同名白板全部保留，按 `lastSeen` 排序：
选中卡片的 scope 前缀（等于白板文档 id 的前缀）能确认用户在哪一块，确认过的排前面。
窗口标题在表里查不到就再爬一次，最多 60 秒一次；查不到期间走下面的回退路径，回退时 `card-content` 的 `parentDocumentId`
会直接学进表里。

**BoardModel（当前白板的所有卡片）**。标题换成 id 后，一次 `board-content <id> --format json` 装入该白板全部卡片
（id、kind、title、frame、createdAt、document.id/body）。刷新时机：

| 时机 | 为什么 |
|---|---|
| 窗口标题变化（`AllumeTracker` 的 AX 标题） | 切换了白板，立即换模型 |
| 面板打开（⌘K） | 和 describeSelection 并行，不阻塞面板；装完后用新数据重刷卡片标题 |
| 每条写命令（排列、统一大小、撤销）完成后 | 把自己改的位置同步进来 |
| Allume 在前台时每 10 秒 | 兜底跟上用户手动的移动；不在前台不刷 |

每次装入后，在后台按阅读顺序对前 12 张有缩略图的卡（image/pdf/subBoard）预热 `ThumbnailLoader` 的缓存，两张并发，
这样 ⌘K 选到它们时图是现成的。所有这些调用在 `AllumeCLI` 里记为"后台"调用，日志行以 `cli[bg]` 开头。

**谁用缓存、谁查 CLI**：

| 场景 | 来源 |
|---|---|
| ⌘K 后补标题/类型/正文（`describeSelection`） | 选中的 id 全在模型里 → 直接用，0 次 CLI；有不在的（跨白板选中、模型还没装好、刚建的卡） → 原路径：`card-content` 取父白板 + `board-content`（scope → 白板 id 已知时跳过 `card-content`） |
| 缩略图 | `ThumbnailLoader` 缓存命中 → 0 次；否则按类型取 1 次 |
| 写命令前的撤销快照（`snapshotFrames`） | 模型 **2 秒内**刷新过且包含全部选中卡 → 用模型（面板日志"位置来自当前白板模型（x 秒前读取）"）；否则现查一次 `board-content`。撤销必须基于写之前的真实位置，这一点不拿缓存换 |
| 排列时按标题/时间排序 | 上一步拿到的行（模型或现查），不另外调用 |

日志里每次 ⌘K 有一行统计：`⌘K 统计：面板显示 N ms（CLI 前台 a 次，后台 b 次）；卡片信息就绪 M ms（CLI 前台 c 次，后台 d 次），k/n 张有标题`。
"前台"是为了这次 ⌘K 才发的调用，"后台"是同时段恰好在跑的刷新/爬表/预热。实测：模型装好后 ⌘K 为
`面板显示 5 ms（前台 0 次）；卡片信息就绪 23 ms（前台 0 次）`，之前是 3–5 次（`card-content` + `board-content` 每块白板各一次，再加缩略图）。

局限：模型最多落后 10 秒（Allume 没有通知）；白板标题重名时靠选中卡片的 scope 纠正，⌘K 之前可能先装错一块；
窗口标题不在表里（新建的白板）时要等重爬，期间一切走回退路径；`boards.json` 只在本机有效。

### 卡片缩略图从哪来

层叠里的每张卡（`CardFace`）按类型显示不同内容；像素都来自 CLI，经 `open -W` 启动，stdout 落到临时文件再读回
（CLI 是沙盒 app，`-o` 写不到任意路径，所以图片字节只能从 stdout 拿，`AllumeCLI.run(…, raw: true)`）：

| 卡片类型 | 来源 | 显示 |
|---|---|---|
| image | `allume card-content <id> --contents raw --format json`：原图 JPEG/PNG 字节在 stdout，元数据 JSON 在 stderr。用 ImageIO 直接解码成最长边 120px 的缩略（不解码整张大图，按 EXIF 方向转正） | 整张卡铺满（aspect fill，圆角裁切），标题叠在底部半透明条上 |
| pdf | `allume card-pdf-page <id> --page 1 --max-dimension 256 --format json`：第一页 PNG 在 stdout，同样缩到 120px | 同上 |
| subBoard | 子白板没有图。`board-content <document.id> --format json`（`document.id` 在 ⌘K 后读的那行 `board-content` 里就有）给出里面每张卡的行，`BoardThumbnailRenderer` 据此离屏画一张 240×180 的白板缩略（见下面"子白板缩略图怎么画"） | 同上，标题是白板名 |
| text、chain | 不取图：`board-content` 行里 `document.body` 就是正文，取前 60 字（空白折叠） | 正文小字，最多 4 行 |
| url、video | 不取图（url 只有链接和标题；video 只有整段 mp4） | 类型图标 + 标题 |

流程：`describeSelection()` 先用 `board-content` 补齐标题/类型/正文（面板已经打开，不等这一步），然后只对层叠显示的
前 3 张（`CardStackView.visible`）并发取图，每张取到就单独写回 `state.selectedCards`，面板随之刷新。
`ThumbnailLoader` 按卡片 id 用 `NSCache` 缓存（最多 48 张），同一张卡在 app 运行期间只取一次；正在取的卡片再被请求时
共用同一次调用。实测（三张分别在不同白板上）：image 原图 990KB → 55×120，约 300–450ms；pdf 9.7KB → 104×120，
约 230–450ms；subBoard 见下面；三张并发，都在面板打开后约半秒到一秒半内到齐。
每张的尺寸和耗时写进 `~/Library/Logs/AllumeCompanion.log`（`thumbnail <kind> <id>: WxH px, …, N ms`）。

局限：只取前 3 张；缩略图不跟卡片内容变化（改了图片要重启 app 才刷新；子白板的缩略图重启后会按内容哈希重新校验）；
pdf 只渲染第一页；`card-pdf-page` 的 `--max-dimension` 最小 256，所以 PDF 总是先渲染 256 再缩到 120。

#### 子白板缩略图怎么画

目标是 Allume 自己的子白板卡片那种效果：白底，里面每张卡缩小后画在原位。`BoardThumbnailRenderer.swift` 的输入是那块白板的
`board-content` 行，输出 240×180 的位图（`NSBitmapImageRep` + 翻转的 `NSGraphicsContext`，在后台任务里画，不碰主线程）：

1. 算所有卡 `frame` 的包围盒，等比缩放到画布（留 6px 边，不放大超过 1:1），居中。
2. 按 `zOrder` 从低到高逐张画：

   | 卡片 | 画法 |
   |---|---|
   | text、chain | 白色圆角矩形 + 细灰边，`document.body`（取前 400 字）用 2–3pt 系统字体按行填进去，超出裁掉——远看是一团文字 |
   | url | 浅蓝灰矩形，标题一行（截尾） |
   | image | `card-content <id> --contents raw`，ImageIO 直接解码成最长边 160px，aspect-fill 填进圆角矩形 |
   | pdf | `card-pdf-page <id> --page 1 --max-dimension 256` 的首页，白底 aspect-fit |
   | subBoard | 灰色圆角块 + 标题一行 |
   | video、file、其他 | 灰块 + SF Symbol 图标（play.fill / doc.fill） |

3. 图片预算：一块白板最多取 **6 张**图（image 和 pdf 合计，按卡在画布上的面积从大到小挑），其余画灰块；两张并发取，
   每张一次 CLI 调用（150–450ms）。所以一张含图的子白板缩略约 0.5–1.2 秒，不含图的几 ms。

缓存按白板文档 id 两层：内存里一份，磁盘上 `~/Library/Application Support/AllumeCompanion/thumbs/<id>.png`
（id 里的 `:` 写成 `_`）旁边放 `<id>.hash`——每行里影响画面的字段（id、kind、title、frame、zOrder、正文、文件名/大小）的 SHA-256。
不能直接哈希整段 JSON：`board-content` 的 `createdAt` 每次调用都是调用当时的时间，原文每次都不同（见下面的局限）。再次请求时先算哈希，
相同就直接用现成的 PNG，不取图不重画（日志 `cache hit (disk), N cards, 0 ms`）；行变了（卡移动、增删、改正文）才重画。
取图失败的那次只留在内存里、不写盘，下次启动会重试。层叠外层 `ThumbnailLoader` 仍按卡片 id 缓存，所以同一次运行里
同一张子白板卡只走一次这条路径。

日志每张一行：`board thumbnail "<白板名>" <文档id>: N cards, M images, k/n pictures fetched, scale s, 240×180 px, T ms (fetch a, draw b)`。
实测（Project 板上的子白板）：3 张嵌套子白板、无图 → 4 ms；12 张卡、4 张图 → 747 ms；29 张卡、16 张图（取 6）→ 1151 ms；
第二次启动全部 `cache hit (disk)`，0–1 ms。`BoardModel` 的预热也走这条路径（`board thumbnail[bg]`），所以当前白板上的
前 12 张子白板在装入后约 4 秒内就有带内容的缩略，之后的启动只剩每张一次 `board-content` 校验哈希。

局限：板上没有墨迹数据（`board-content` 只给 `inkStrokeCount`），手写内容画不出来；一块白板最多 6 张真图；
嵌套子白板只画灰块（不递归）；颜色固定为白底灰块，不跟深色模式。`createdAt` 实测每次调用都变（等于调用时间），
所以它不进哈希——这也意味着"按时间"排序拿到的创建时间并不可靠，待查。

### 撤销上一步

**为什么 Allume 自己的 ⌘Z 不管用**：CLI 的移动走的是 Allume 的 helper 管道（CLI 进程 → app 内的命令处理器
→ 直接改文档），不经过界面层的 undo manager，所以在 Allume 里按 ⌘Z 撤不掉 CLI 做的事（实测）。
只能用 CLI 自己把状态改回去：`allume card-move`（如果用 CLI 删过卡，`allume undelete <id>` 能恢复）。

于是 `CommandRunner` 在每条命令执行前先记下恢复所需的状态，面板里的"撤销"命令：

| 命令 | 执行前记录 | 撤销 = |
|---|---|---|
| 排成 N 列 / 统一大小 | 每张卡当前的 frame（x,y,w,h） | 逐张 `allume card-move --id … --x … --y … --width … --height …` 回到原值 |

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
- 快照通常要一次 `board-content`（约 150–350ms）；白板模型 2 秒内刷新过就省掉这次（见"当前白板模型"）。
  面板日志只显示命令行和"已记录 N/M 张"，不显示 JSON。

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
  AllumeCLI.swift                  经 open -W 调 allume（原因见上）；前台/后台调用计数
  BoardIndex.swift                 标题 → 白板文档 id 表：BFS 爬取、boards.json 缓存、限频重爬
  BoardModel.swift                 当前白板的卡片副本（BoardCard 行）：解析标题、四种刷新时机、缩略图预热
  CommandRunner.swift              三条命令 + 一层撤销（执行前记 frame，优先用新鲜的模型）；describeSelection 先查模型再回退 CLI
  ThumbnailLoader.swift            按类型取缩略图（image/pdf 字节、subBoard 交给 BoardThumbnailRenderer），NSCache 按卡片 id 缓存
  BoardThumbnailRenderer.swift     用 board-content 行离屏画 240×180 的白板缩略（文字、图片、PDF、嵌套白板），按白板 id 缓存到内存 + thumbs/ 目录
  OverlayController.swift          命令面板 NSPanel 及定位
  CommandCatalog.swift             命令表、多语言别名、参数解析（纯 Swift，可单独 swiftc 测）
  Views.swift                      SwiftUI：CommandPanelView（输入框 + 结果列表）、CardStackView / CardFace（缩略图、正文、图标三种面）
  Log.swift                        ~/Library/Logs/AllumeCompanion.log
```

## 协议

MIT，见 [LICENSE](LICENSE)。Allume 是 Muse Software 的产品，本项目与其无关，只是通过它公开的命令行工具和剪贴板格式配合工作。
