#!/bin/zsh
# Rebuild, quit any running copy, and launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-release}"
pkill -x AllumeCompanion 2>/dev/null || true
sleep 0.3
open build/AllumeCompanion.app
echo "launched; log: log stream --predicate 'process == \"AllumeCompanion\"' --level info"
