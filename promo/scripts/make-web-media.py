#!/usr/bin/env python3
"""Videos for the landing page (companion.maverickli.org), from the same masters and ranges as the film:

  <feature>.mp4 + .jpg   a silent loop per feature: the ranges of src/clips.json back to back (the still
                         waits cut out), the last frame held a moment before it loops; 1280 wide, 60 fps.
                         "todos" joins the add and the finish clips.
  promo.mp4 + .jpg       the film (out/allume-companion-promo.mp4) at a web bitrate, with its poster.

Usage: scripts/make-web-media.py <out dir>   (e.g. ../../blog/public/projects/allume-companion)
"""
import json
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
MASTERS = os.path.join(ROOT, "..", "build", "masters")
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
clips = json.load(open(os.path.join(ROOT, "src", "clips.json")))["clips"]

LOOPS = {
    "arrange": ["arrange"],
    "same-size": ["sameSize"],
    "undo": ["undo"],
    "jump": ["jump"],
    "todos": ["addTodo", "doneTodo"],
    "daily": ["daily"],
    "projects": ["projects"],
}
HOLD = 1.2  # seconds the result stays before the loop starts over


def run(args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


for name, ids in LOOPS.items():
    ranges = [(clips[i]["file"], a, b) for i in ids for a, b in clips[i]["ranges"]]
    inputs, chains = [], []
    for k, (file, a, b) in enumerate(ranges):
        inputs += ["-ss", str(a), "-t", str(b - a), "-i", os.path.join(MASTERS, f"{file}.mov")]
        chains.append(f"[{k}:v]fps=60,scale=1280:-2:flags=lanczos,setpts=PTS-STARTPTS[v{k}]")
    joined = "".join(f"[v{k}]" for k in range(len(ranges)))
    graph = ";".join(chains) + f";{joined}concat=n={len(ranges)}:v=1:a=0,tpad=stop_mode=clone:stop_duration={HOLD}[out]"
    mp4 = os.path.join(OUT, f"{name}.mp4")
    run([*inputs, "-filter_complex", graph, "-map", "[out]", "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "24",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4])
    run(["-sseof", "-0.05", "-i", mp4, "-frames:v", "1", "-q:v", "3", os.path.join(OUT, f"{name}.jpg")])
    print(name, f"{os.path.getsize(mp4) / 1e6:.2f} MB")

film = os.path.join(ROOT, "out", "allume-companion-promo.mp4")
promo = os.path.join(OUT, "promo.mp4")
run(["-i", film, "-c:v", "libx264", "-preset", "slow", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
     "-movflags", "+faststart", promo])
# the poster: the closing lockup (icon, name, address)
run(["-ss", "60", "-i", film, "-frames:v", "1", "-q:v", "2", os.path.join(OUT, "promo.jpg")])
print("promo", f"{os.path.getsize(promo) / 1e6:.2f} MB")
