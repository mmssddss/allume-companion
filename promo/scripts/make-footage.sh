#!/bin/zsh
# The film's footage: each editing master (../build/masters, from make-demo-media.sh with
# MASTER_DIR) as near-lossless H.264 at full size, which Remotion decodes much faster than ProRes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p public/footage
for f in ../build/masters/*.mov; do
  name="$(basename "$f" .mov)"
  ffmpeg -v error -y -i "$f" -an -c:v libx264 -preset slow -crf 12 -pix_fmt yuv420p -g 30 -movflags +faststart \
    "public/footage/$name.mp4"
  echo "$name $(du -h "public/footage/$name.mp4" | cut -f1)"
done

# Stills: the first and last frame each scene shows (src/clips.json), for the moments a clip is
# on screen but not playing (before its turn, after it ends, the wall of all features).
mkdir -p public/footage/stills
python3 -I - <<'PY'
import json, subprocess
c = json.load(open("src/clips.json"))["clips"]
for cid, clip in c.items():
    for which, t in (("start", clip["ranges"][0][0]), ("end", clip["ranges"][-1][1])):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", f"public/footage/{clip['file']}.mp4",
                        "-frames:v", "1", "-vf", "scale=1600:-2:flags=lanczos", "-q:v", "2",
                        f"public/footage/stills/{cid}-{which}.jpg"], check=True)
        print(cid, which, t)
PY
