#!/usr/bin/env python3
"""Puts the Demo board back the way the shots start (docs/DEVELOPMENT.md "演示视频"), so every
take of every shot begins from the same picture:

- Japan Trip: the nine notes scattered at their original positions and sizes (arrange, undo, same size)
- Trip Ideas: the ryokan todo open again and two days overdue; todos added in the todos shot removed
- Projects: every project board back on Todo, in the order Tax return, Japan trip, Website redesign

Usage: scripts/reset-demo-board.py <manifest from make-demo-board.py> [companion-demo.json]
Quit the companion first, or restart it after: it keeps companion-demo.json (where each project
is recorded as on Todo / Doing / Done, which decides the commands it offers) in memory.
"""
import datetime
import json
import os
import subprocess
import sys

# Same as make-demo-board.py: body prefix → x, y, width, height.
TRIP = {
    "Kyoto": (90, 70, 260, 120), "Ramen": (420, 140, 220, 160), "JR Pass": (760, 60, 180, 90),
    "Hotel": (140, 300, 300, 100), "Packing": (520, 380, 240, 140), "Day 1": (860, 260, 200, 120),
    "Onsen": (60, 470, 190, 90), "Budget": (330, 560, 280, 90), "Matcha": (820, 520, 180, 110),
}
PROJECT_ORDER = ["project-Tax return", "project-Japan trip", "project-Website redesign"]
ORIGIN, PITCH_X = 80, 240  # CompanionLayout.origin / pitchX


def allume(*args):
    r = subprocess.run(["allume", *map(str, args)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"allume {' '.join(map(str, args))}: {r.stderr.strip()}")
    return r.stdout


def rows(board):
    return json.loads(allume("board-content", board, "--format", "json"), strict=False)


manifest = json.load(open(sys.argv[1]))
boards = {m["title"]: m["board"] for m in manifest["made"] if m.get("title")}
companion = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser(
    "~/Library/Application Support/AllumeCompanion/companion-demo.json")
registry = json.load(open(companion))
lists = next(iter(registry.values()))["lists"]

for r in rows(boards["Japan Trip"]):
    for prefix, (x, y, w, h) in TRIP.items():
        if r["document"].get("body", "").startswith(prefix):
            allume("card-move", "--id", r["id"], "--x", x, "--y", y, "--width", w, "--height", h)

overdue = (datetime.date.today() - datetime.timedelta(days=2)).isoformat()
for r in rows(boards["Trip Ideas"]):
    body = r["document"].get("body", "")
    if "Osaka" in body:
        allume("delete", r["id"])
    elif "ryokan" in body:
        allume("note-update", "--document-id", r["document"]["id"], "--body",
               f"@todo(due: {overdue}) Book the ryokan in Hakone", "--format", "id")

# A project moved by the shot is re-mounted on Todo (the board itself, with everything on it).
for status in ("doing", "done"):
    for r in rows(lists[status]):
        if r["kind"] == "subBoard":
            allume("card-create", "--parent", lists["todo"], "--document", r["document"]["id"], "--format", "id")
            allume("delete", r["id"])
on_todo = {(r["document"].get("title") or r.get("title")): r for r in rows(lists["todo"]) if r["kind"] == "subBoard"}
for i, title in enumerate(PROJECT_ORDER):
    if title in on_todo:
        allume("card-move", "--id", on_todo[title]["id"], "--x", ORIGIN + i * PITCH_X, "--y", ORIGIN)
for r in registry.values():
    r["projectBoards"] = {board: "todo" for board in r.get("projectBoards", {})}
with open(companion, "w") as f:
    json.dump(registry, f, indent=2, sort_keys=True)
print("demo board reset")
