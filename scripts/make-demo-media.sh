#!/bin/zsh
# Turns the screen recording of one feature into what the README and the landing page show
# (docs/DEVELOPMENT.md "演示视频"):
#   <name>.mp4 + <name>.webm  the landing page's looping video: 1280 wide, 30 fps, no audio
#   <name>.jpg                its poster, the last frame (the result), also shown with reduced motion
#   <name>.gif                the README's: 800 wide, 12 fps, one palette per clip
#
# Usage: scripts/make-demo-media.sh <recording.mov> <name> [out dir, default build/demo-media]
set -euo pipefail
IN="${1:?usage: scripts/make-demo-media.sh <recording.mov> <name> [out dir]}"
NAME="${2:?name}"
OUT="${3:-build/demo-media}"
mkdir -p "$OUT"
WEB="fps=30,scale=1280:-2:flags=lanczos"

ffmpeg -v error -y -i "$IN" -an -vf "$WEB" -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p \
  -movflags +faststart "$OUT/$NAME.mp4"
ffmpeg -v error -y -i "$IN" -an -vf "$WEB" -c:v libvpx-vp9 -crf 36 -b:v 0 -row-mt 1 "$OUT/$NAME.webm"
# every frame overwrites the same file, so the last one stays
ffmpeg -v error -y -i "$IN" -vf "scale=1280:-2:flags=lanczos" -update 1 -q:v 3 "$OUT/$NAME.jpg"
ffmpeg -v error -y -i "$IN" -vf "fps=12,scale=800:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$OUT/$NAME.gif"

ls -lh "$OUT/$NAME".{mp4,webm,jpg,gif} | awk '{print $5, $NF}'
