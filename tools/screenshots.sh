#!/bin/bash
# Regenerate every iOS screenshot in the README, from a clean simulator.
#
# Nothing here is mocked up in a design tool and nothing is hand-edited. Each
# image is the shipping view, rendered from a plan the real engine produced from
# a real itinerary -- see DemoTrips in App/Circadia/Support/DemoScreens.swift.
#
#   tools/screenshots.sh              # default simulator
#   tools/screenshots.sh "iPhone 16"  # a specific one
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
BUNDLE_ID="com.foggylulu.circadia"
OUT="docs/images"
DD="build/screenshots"

UDID=$(xcrun simctl list devices available \
  | grep -m1 -F "$DEVICE (" \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$UDID" ]; then
  echo "No available simulator called '$DEVICE'." >&2
  echo "Pick one from: xcrun simctl list devices available" >&2
  exit 1
fi
echo "Simulator: $DEVICE ($UDID)"

mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

echo "Building..."
xcodebuild -project Circadia.xcodeproj -scheme Circadia \
  -destination "id=$UDID" -configuration Debug -derivedDataPath "$DD" \
  build >/dev/null

APP="$DD/Build/Products/Debug-iphonesimulator/Circadia.app"
xcrun simctl install "$UDID" "$APP"

# A fixed status bar keeps the images stable between runs.
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 2>/dev/null || true

capture() {  # capture <demoScreen> <output-name>
  echo "  $2.png"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoScreen "$1" >/dev/null
  sleep 4
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$2.png" >/dev/null 2>&1
}

echo "Capturing..."
capture plan       hero
capture day        day
capture trips      trips
capture science    science
capture onboarding onboarding

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
echo "Wrote $(ls -1 "$OUT"/*.png | wc -l | tr -d ' ') images to $OUT"
