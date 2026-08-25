#!/bin/bash
# Build, run and capture the macOS app window for the README.
#
# Captures the window by id rather than a screen region, so nothing else on the
# desktop can end up in the frame. Uses Swift rather than Python for the window
# lookup, so the only dependency is the toolchain you already need to build.
set -euo pipefail
cd "$(dirname "$0")/.."

DD="build/mac-screenshot"
OUT="docs/images/macos.png"
mkdir -p docs/images

echo "Building..."
xcodebuild -project Circadia.xcodeproj -scheme Circadia \
  -destination 'platform=macOS' -configuration Debug -derivedDataPath "$DD" \
  build >/dev/null

APP=$(find "$PWD/$DD/Build/Products" -maxdepth 2 -name 'Circadia.app' | head -1)
[ -n "$APP" ] || { echo "Could not find the built app." >&2; exit 1; }

open -a "$APP" --args -demoScreen plan
sleep 7

WINDOW_ID=$(cat <<'SWIFT' | swift - 2>/dev/null
import CoreGraphics
import Foundation
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
    for window in windows
    where window[kCGWindowOwnerName as String] as? String == "Circadia"
       && window[kCGWindowLayer as String] as? Int == 0 {
        if let number = window[kCGWindowNumber as String] as? Int {
            print(number)
            break
        }
    }
}
SWIFT
)

if [ -n "$WINDOW_ID" ]; then
  screencapture -o -x -l "$WINDOW_ID" "$OUT"
else
  echo "Could not resolve the Circadia window id." >&2
  echo "Grant Screen Recording permission to your terminal and try again." >&2
  osascript -e 'tell application "Circadia" to quit' >/dev/null 2>&1 || true
  exit 1
fi

osascript -e 'tell application "Circadia" to quit' >/dev/null 2>&1 || true
echo "Wrote $OUT"
