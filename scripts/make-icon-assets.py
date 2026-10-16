#!/usr/bin/env python3
"""Writes the SVG layers of Resources/AppIcon.icon (run after changing the geometry here).

The icon follows Allume's own: an indigo gradient fill, white Liquid Glass shapes, and the
looping "filament" line from Allume's mark. Ours shows what the companion works on: the
stack of selected cards from the ⌘K panel (three 4:3 cards, Allume's default card ratio),
the top one carrying the filament in Allume's accent colour.
"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources", "AppIcon.icon", "Assets")
CANVAS = 1024
CARD_W, CARD_H, CARD_R = 560, 420, 48
# Centres of back, middle, top card: the panel's CardStackView offsets each card up-right.
CENTERS = [(556, 468), (512, 512), (468, 556)]

def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n{body}\n</svg>\n')

def card(cx, cy):
    x, y = cx - CARD_W / 2, cy - CARD_H / 2
    return f'  <rect x="{x:.0f}" y="{y:.0f}" width="{CARD_W}" height="{CARD_H}" rx="{CARD_R}" fill="#FFFFFF"/>'

def filament(cx, cy):
    """A prolate cycloid: a line that loops twice as it travels, like Allume's filament."""
    r, d = 22, 50          # wheel radius / pen distance (> r gives loops)
    loops = 2
    pts = []
    t0, t1 = -0.5 * math.pi, loops * 2 * math.pi + 0.5 * math.pi
    n = 160
    for i in range(n + 1):
        t = t0 + (t1 - t0) * i / n
        x = r * t - d * math.sin(t)
        y = -d * math.cos(t) * 1.1
        pts.append((x, y))
    # Lead-in / lead-out: straighten the ends into gentle tails.
    xs = [p[0] for p in pts]; mid = (min(xs) + max(xs)) / 2
    path = " ".join(f"{'M' if i == 0 else 'L'}{cx + x - mid:.1f},{cy + y:.1f}" for i, (x, y) in enumerate(pts))
    # A slight tilt keeps it from reading as a bow: Allume's filament is handwritten, not set.
    return (f'  <path d="{path}" fill="none" stroke="#6329F5" stroke-width="26" '
            f'stroke-linecap="round" stroke-linejoin="round" transform="rotate(-7 {cx} {cy})"/>')

os.makedirs(OUT, exist_ok=True)
for name, (cx, cy) in zip(["card-back", "card-mid", "card-top"], CENTERS):
    with open(os.path.join(OUT, name + ".svg"), "w") as f:
        f.write(svg(card(cx, cy)))
tx, ty = CENTERS[2]
with open(os.path.join(OUT, "filament.svg"), "w") as f:
    f.write(svg(filament(tx, ty + 6)))
print("wrote", sorted(os.listdir(OUT)))
