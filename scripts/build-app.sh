#!/bin/zsh
# Build the SwiftPM executable and wrap it into build/AllumeCompanion.app.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/AllumeCompanion.app"

swift build -c "$CONFIG" 2>&1 | grep -v -E '^\s*$' || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AllumeCompanion"
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AllumeCompanion"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with a stable identity when one exists so macOS keeps the Accessibility
# grant across rebuilds; ad-hoc signing re-prompts after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.maverickli.allume-companion "$APP" >/dev/null
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - --identifier com.maverickli.allume-companion "$APP" >/dev/null
  echo "signed ad-hoc (Accessibility permission will need re-granting after each rebuild)"
fi
echo "built $APP"
