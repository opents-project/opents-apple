#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-apple-core.sh
xcodebuild -project OpenTS.xcodeproj -scheme OpenTS-macOS -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Xcode build
app="$PWD/build/Xcode/Build/Products/Debug/OpenTS.app"
pkill -x OpenTS || true
open -n "$app"
if [[ "${1:-}" == "--verify" ]]; then
  sleep 1
  pgrep -x OpenTS >/dev/null
fi
