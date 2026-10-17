# Allume Companion

English | [中文](README.md)

A command palette for [Allume](https://allume.com) (formerly Muse) boards. Press **⌘K** in Allume and a
Raycast-style panel drops down from the top of the Allume window: arrange or resize the cards you selected,
jump to any board, add todos, keep daily notes and move projects between Todo / Doing / Done. Esc, ⌘K again,
or clicking back into Allume closes it. Otherwise the app stays out of sight in the menu bar.

Everything goes through Allume's own command-line tool, `/usr/local/bin/allume`. The companion never
takes screenshots or clicks inside Allume; the only keys it sends Allume are ⌘C (to read which cards are
selected) and one ⌘[ after jumping to a board (so Allume redraws its breadcrumb).

The interface is in English or Chinese, following the system language.

## Install

1. Download the latest `AllumeCompanion-<version>.zip` from
   [Releases](https://github.com/mmssddss/allume-companion/releases), unzip it and drag
   **AllumeCompanion.app** into Applications. It is signed and notarized. macOS 14 or later.
2. Open it. If something is missing, the settings window opens on the **Allume** tab and walks you through
   the steps below; the first menu bar item also says what to do next.

### Set up Allume's command-line tool

The companion needs Allume itself (from allume.com or Setapp) and its command-line tool:

1. Open Allume. The CLI only works while Allume is running.
2. In Allume's **Settings → CLI**, install the command-line tool (it goes to `/usr/local/bin/allume`).
3. In the same place, switch the CLI to **read-write**. It is read-only by default, and then arranging,
   resizing and adding todos fail with "the CLI is in read-only mode". Click **Check Again** on the
   companion's Allume tab; all four rows should be green.

## Permissions

| Permission | Used for | Without it |
|---|---|---|
| Accessibility | Following the Allume window so the panel sits on top of it, and sending ⌘C to Allume to read the selection | The panel does not appear and ⌘K cannot see what is selected |
| Notifications (optional) | Due-date reminders for todos | No reminders; everything else works |

macOS asks on first launch; the settings window's **General** tab shows both and links to System Settings.
No Input Monitoring is needed: ⌘K is a Carbon hot key, registered only while Allume is the frontmost app,
so ⌘K in other apps is left alone.

## Commands

With nothing typed, the panel lists what fits the selection:

| Selection | Commands |
|---|---|
| Nothing | Recent Boards, All Todos, Home, Today, Yesterday, Tomorrow, This Month · Add Todo, Add to Day, New Project · Undo (when there is a step to undo) |
| One card | Same Size (Small 160×120 / Medium 200×150 / Large 280×210), plus the above; for a sub-board, **Open** it |
| Several cards | Arrange in N Columns, in a Row, in a Column · Same Size · the above |
| A project board | Mark Done, Move to Doing, Move to Todo |

Type to filter: commands, boards (by title, anywhere in the workspace) and todos are matched together.
Commands answer to English, Chinese and pinyin names, and numbers become arguments: `grid 4`,
`row reverse`, `column by title`, `grid 2 by date`. ↑↓ to pick, ⏎ to run, Esc to close.

**Undo** reverts the last arrange or resize by moving the cards back with the CLI (Allume's own ⌘Z
does not see changes made through the CLI). One step only. There is no delete command: Allume's Delete
key does that, with its own ⌘Z.

## Todos

A todo is a text card whose first line starts with `@todo`; with a due date it is
`@todo(due: 2026-10-20) pay rent`. Change `@todo` to `@done` when it is done.

- **All Todos** lists every todo in the workspace, overdue and due first; ⏎ jumps to its board.
  The workspace is scanned every 15 minutes (Settings → Data → Rescan to do it now).
- **Add Todo** sticks a new todo card in the middle of what you are looking at. Put the date at the
  start or end in plain words: `tomorrow`, `Friday`, `in 3 days`, `Oct 20`, `10-20`. Chinese phrases
  (`明天`, `下周二`, `月底`, `3天后`) work too, with Tab completion.
- **Reminders**: a todo with a due date gets a notification at 9:00 on that day (time adjustable in
  Settings → Reminders); clicking it opens the board.

## Daily notes and projects

The companion keeps its own board, `workspace-Companion`, on the workspace's root board, and writes
nowhere else:

```
workspace-Companion
├─ Daily Notes › 2026 › 2026-10 › 2026-10-17
└─ Projects › Todo / Doing / Done › project-<name>
```

- **Today / Yesterday / Tomorrow / This Month** jump to that day's (or month's) board, creating it if needed.
  Month boards lay the days out as a calendar.
- **Add to Day** adds a todo card to a day's board without leaving the board you are on (today if no date
  is typed).
- **New Project** creates a `project-<name>` board in Todo (or Doing, see Settings).
  **Mark Done / Move to Doing / Move to Todo** move the selected project boards, or the project board you
  are in. Only `project-` boards on those three lists are ever moved.

## Build from source

Swift Package, no Xcode project; needs the Xcode command-line tools (Swift 5.9+).

```bash
scripts/run.sh    # build release, wrap into build/AllumeCompanion.app, sign, open
```

The log is at `~/Library/Logs/AllumeCompanion.log`. The Chinese [README](README.md) covers how it works
in detail: reading the selection through the clipboard, the board model and caches, thumbnails, and the
known fragile spots.

## License

MIT, see [LICENSE](LICENSE). Allume is a product of Muse Software; this project is not affiliated with it
and only works with Allume's public command-line tool and clipboard format.
