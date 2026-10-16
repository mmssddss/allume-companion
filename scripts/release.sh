#!/bin/zsh
# Package a release: stamp the version, build, sign with Developer ID, zip, optionally
# notarize, and (with --publish) tag + push + create the GitHub Release.
#
# Usage: scripts/release.sh <version> [--publish]
#   NOTARY_PROFILE=<keychain profile>  notarize + staple (set up once with
#                                      `xcrun notarytool store-credentials <profile>`)
#   CODESIGN_IDENTITY=<identity>       override the signing identity
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH=0; [[ "${2:-}" == "--publish" ]] && PUBLISH=1
APP="build/AllumeCompanion.app"
ZIP="dist/AllumeCompanion-$VERSION.zip"

[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean; commit first" >&2; exit 1; }

# 1. Version: CFBundleShortVersionString = the tag, CFBundleVersion = commit count (monotonic).
BUILD_NUMBER="$(git rev-list --count HEAD)"
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" Resources/Info.plist
if [[ -n "$(git status --porcelain Resources/Info.plist)" ]]; then
  git add Resources/Info.plist
  git commit -q -m "Version $VERSION (build $BUILD_NUMBER)"
  BUILD_NUMBER="$(git rev-list --count HEAD)"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" Resources/Info.plist
  git commit -q -am "Version $VERSION (build $BUILD_NUMBER)" --amend
fi

# 2. Build + sign. Developer ID is what Gatekeeper accepts for downloads; the Accessibility
#    grant also stays valid across versions because the signing identity does not change.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
CODESIGN_IDENTITY="$IDENTITY" scripts/build-app.sh release
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier com.maverickli.allume-companion "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

# 3. Zip (ditto keeps the bundle's signatures and symlinks intact).
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 4. Notarize when a profile is configured; otherwise say what that means for users.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarized and stapled"
else
  echo "NOT notarized: downloaded copies will need right-click → Open (or xattr -d com.apple.quarantine) the first time."
fi
spctl --assess --type execute --verbose=1 "$APP" 2>&1 || true
shasum -a 256 "$ZIP"

# 5. Publish.
if (( PUBLISH )); then
  git tag -a "v$VERSION" -m "v$VERSION"
  git push origin main "v$VERSION"
  gh release create "v$VERSION" "$ZIP" --title "v$VERSION" --generate-notes
  echo "released v$VERSION"
else
  echo "built $ZIP; run again with --publish to tag, push and create the GitHub Release"
fi
