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

# App icon: Resources/AppIcon.icon is an Icon Composer document (layers in Assets/*.svg, drawn by
# scripts/make-icon-assets.py). actool turns it into Assets.car (the Liquid Glass icon macOS 26+
# renders) plus AppIcon.icns for older systems; Info.plist already names both as "AppIcon".
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon --target-device mac \
  --output-partial-info-plist "$APP/Contents/icon-info.plist" --output-format human-readable-text \
  | grep -iE 'warning|error' || true
rm -f "$APP/Contents/icon-info.plist"
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { echo "actool produced no Assets.car" >&2; exit 1; }

# Sign with a stable identity when one exists so macOS keeps the Accessibility
# grant across rebuilds; ad-hoc signing re-prompts after every build. Prefer Developer ID
# (falling back to Apple Development) so dev builds and release.sh builds share one identity:
# TCC ties the grant to the signing certificate, and switching identities re-prompts.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.maverickli.allume-companion "$APP" >/dev/null
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - --identifier com.maverickli.allume-companion "$APP" >/dev/null
  echo "signed ad-hoc (Accessibility permission will need re-granting after each rebuild)"
fi
echo "built $APP"
