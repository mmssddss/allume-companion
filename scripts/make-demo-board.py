#!/usr/bin/env python3
"""Builds the Demo board the feature videos are recorded on (docs/DEVELOPMENT.md "演示视频").

Allume has one workspace and the CLI cannot make another, so the demo lives on one board,
"Demo", on the workspace's home board right of everything there, with neutral sample content:

    Demo
    ├─ Japan Trip        nine notes of mixed sizes, scattered: arrange / same size / undo
    ├─ Trip Ideas        a few notes and an overdue todo (search "trip" finds two boards)
    ├─ Home Renovation   dated todos: today, in two days, undated
    ├─ Reading Notes
    └─ Recipes

Run the companion with ALLUME_DEMO_ROOT=<printed id> so the panel only shows these boards.
Due dates count from today. Prints the Demo board id; ids of everything made go to the
manifest (argv[1], default ./demo-board.json) so it can be removed with `allume delete`.
"""
import datetime
import json
import subprocess
import sys


def allume(*args):
    r = subprocess.run(["allume", *map(str, args)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"allume {' '.join(map(str, args))}: {r.stderr.strip()}")
    return r.stdout


def rows(out):
    return json.loads(out, strict=False)


made = []


def board(title, parent, x, y):
    doc = allume("board-create", "-w", WORKSPACE, "--title", title, "--format", "id").strip()
    card = rows(allume("card-create", "--parent", parent, "--document", doc, "--x", x, "--y", y, "--format", "json"))[0]["id"]
    made.append({"card": card, "board": doc, "title": title})
    return doc


def note(parent, body, x, y, w=None, h=None):
    card = rows(allume("card-add", "--parent", parent, "--text", body, "--x", x, "--y", y, "--format", "json"))[0]["id"]
    if w:
        allume("card-move", "--id", card, "--x", x, "--y", y, "--width", w, "--height", h)
    made.append({"card": card})
    return card


def due(days):
    return (datetime.date.today() + datetime.timedelta(days=days)).isoformat()


workspace = rows(allume("list-workspaces", "--format", "json"))[0]
WORKSPACE, HOME = workspace["id"], workspace["rootBoardId"]
on_home = rows(allume("board-content", HOME, "--format", "json"))
right = max((r["frame"]["x"] + r["frame"]["width"] for r in on_home), default=0)
top = min((r["frame"]["y"] for r in on_home), default=100)

demo = board("Demo", HOME, round(right + 120), round(top))

trip = board("Japan Trip", demo, 80, 80)
for body, x, y, w, h in [
    ("Kyoto: Fushimi Inari at sunrise", 90, 70, 260, 120),
    ("Ramen list\nIchiran · Afuri · Fuunji", 420, 140, 220, 160),
    ("JR Pass, 7 days", 760, 60, 180, 90),
    ("Hotel in Shinjuku booked", 140, 300, 300, 100),
    ("Packing\nadapter, umbrella, cash", 520, 380, 240, 140),
    ("Day 1: Asakusa and Skytree", 860, 260, 200, 120),
    ("Onsen day in Hakone", 60, 470, 190, 90),
    ("Budget ¥250,000", 330, 560, 280, 90),
    ("Matcha in Uji", 820, 520, 180, 110),
]:
    note(trip, body, x, y, w, h)

ideas = board("Trip Ideas", demo, 340, 80)
note(ideas, "Iceland in winter: northern lights", 80, 80)
note(ideas, "Lisbon long weekend", 80, 200)
note(ideas, f"@todo(due: {due(-2)}) Book the ryokan in Hakone", 420, 80)

home = board("Home Renovation", demo, 600, 80)
note(home, f"@todo(due: {due(0)}) Call the plumber", 80, 80)
note(home, f"@todo(due: {due(2)}) Order paint samples", 80, 200)
note(home, "@todo Pick bathroom tiles", 80, 320)
note(home, "Kitchen: open shelves, warm wood", 440, 80)

reading = board("Reading Notes", demo, 80, 320)
note(reading, "Deep Work: schedule every minute of the day", 80, 80)
note(reading, "The Mom Test: ask about the past, not the future", 80, 200)

recipes = board("Recipes", demo, 340, 320)
note(recipes, "Miso soup: dashi, tofu, wakame, scallion", 80, 80)

manifest = sys.argv[1] if len(sys.argv) > 1 else "demo-board.json"
with open(manifest, "w") as f:
    json.dump({"demo": demo, "workspace": WORKSPACE, "made": made}, f, indent=2)
print(demo)
