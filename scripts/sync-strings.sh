#!/bin/zsh
# Sync Resources/Localizable.xcstrings with the strings in the code, the way Xcode would:
# compile with -emit-localized-strings (every String(localized:) and SwiftUI Text("…") literal),
# then `xcstringstool sync` adds new keys and marks vanished ones stale. Lists the keys that still
# have no English translation; add those to the catalog by hand (or in Xcode's catalog editor).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/strings"
swift build -c debug --build-path "$TMP/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP/strings" >/dev/null
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$TMP"/strings/*.stringsdata
/usr/bin/python3 - <<'EOF'
import json, re
d = json.load(open("Resources/Localizable.xcstrings"))
cjk = re.compile(r"[　-鿿＀-￯]")
todo = [k for k, e in d["strings"].items()
        if e.get("shouldTranslate", True) and (cjk.search(k) or k.startswith("section."))
        and "en" not in e.get("localizations", {})]
stale = [k for k, e in d["strings"].items() if e.get("extractionState") == "stale"]
for k in todo: print("no English:", k)
for k in stale: print("stale (no longer in the code):", k)
print(f"{len(d['strings'])} keys, {len(todo)} untranslated, {len(stale)} stale")
EOF
