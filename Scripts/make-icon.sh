#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build Resources
swift Scripts/make-icon.swift build/TriBoost.iconset
iconutil -c icns build/TriBoost.iconset -o Resources/TriBoost.icns
echo "wrote Resources/TriBoost.icns"
