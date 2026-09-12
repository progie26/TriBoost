#!/bin/bash
# Rebuild, reinstall into /Applications, and clear the stale permission record.
#
# Why the reset is needed: without an Apple code-signing certificate the app can
# only be signed ad-hoc, and an ad-hoc signature ties the Accessibility grant to
# the exact binary hash. Every rebuild therefore produces an app macOS considers
# unknown, while System Settings still shows a switch left over from the previous
# build — it looks enabled but grants nothing. Clearing the record first means you
# get a fresh, working prompt instead of a stuck one.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="app.triboost.TriBoost"
DEST="/Applications/TriBoost.app"

echo "==> Quitting any running copy"
pkill -f "TriBoost.app/Contents/MacOS/TriBoost" 2>/dev/null || true
sleep 1

./Scripts/build-app.sh release

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R build/TriBoost.app "$DEST"

echo "==> Clearing the stale Accessibility record"
tccutil reset Accessibility "$BUNDLE_ID" || true

echo "==> Launching"
open "$DEST"

cat <<'EOF'

Grant the permission now:

  System Settings > Privacy & Security > Accessibility
    - if a TriBoost row is already there, select it and remove it with "−"
    - then switch TriBoost on

The app polls once a second, so it starts working the moment you flip the switch
— no restart needed. The menu bar status should change from
"缺少辅助功能权限" to "等待三指".
EOF
