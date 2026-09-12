#!/bin/bash
# Builds TriBoost.app from the Swift package.
#
# The app is signed ad-hoc with a stable identifier so that the Accessibility
# permission survives rebuilds — without this macOS treats each new binary as a
# different app and you have to re-authorise every time.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/TriBoost.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product TriBoost

BIN="$(swift build -c "$CONFIG" --product TriBoost --show-bin-path)/TriBoost"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TriBoost"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/TriBoost.icns ]; then
  echo "==> Generating icon"
  ./Scripts/make-icon.sh >/dev/null
fi
cp Resources/TriBoost.icns "$APP/Contents/Resources/TriBoost.icns"

# Bundle the multitouch framework the binary links against.
FRAMEWORK_DIR="$(dirname "$BIN")"
if [ -d "$FRAMEWORK_DIR/OpenMultitouchSupportXCF.framework" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FRAMEWORK_DIR/OpenMultitouchSupportXCF.framework" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/TriBoost" 2>/dev/null || true
fi

echo "==> Signing (ad-hoc, stable identifier)"
codesign --force --deep --sign - \
         --identifier app.triboost.TriBoost \
         "$APP"

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built: $APP"
echo "Run:   open $APP"
echo
echo "First launch needs Accessibility approval:"
echo "  System Settings > Privacy & Security > Accessibility > enable TriBoost"
