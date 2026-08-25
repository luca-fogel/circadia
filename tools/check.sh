#!/bin/bash
# The checks CI runs, in a script so you can run them too:
#
#     tools/check.sh
#
# The app target is deliberately not built here. It needs Xcode 16+ and the iOS
# SDK, and pinning CI to a runner image that may not have them buys a red badge
# that says nothing about the code. The README gives the two xcodebuild commands
# for a local check instead.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }

step "Engine tests"
swift test --package-path Packages/CircadianKit

step "The engine must not depend on SwiftUI, UIKit or AppKit"
# It is a model, and keeping it UI-free is what lets it be tested in a tenth of a
# second with no simulator. A stray import here would end that quietly.
if grep -rn --include='*.swift' -E '^import (SwiftUI|UIKit|AppKit|SwiftData)' \
     Packages/CircadianKit/Sources >/dev/null 2>&1; then
  grep -rn --include='*.swift' -E '^import (SwiftUI|UIKit|AppKit|SwiftData)' Packages/CircadianKit/Sources
  bad "UI framework imported into the engine"
else
  ok "engine imports Foundation only"
fi

step "No absolute home paths in tracked files"
if git grep -In -e '/Users/' -- . ':!tools/check.sh' >/dev/null 2>&1; then
  git grep -In -e '/Users/' -- . ':!tools/check.sh'
  bad "absolute path committed"
else
  ok "none"
fi

step "No local signing identity committed"
if git ls-files --error-unmatch Local.xcconfig >/dev/null 2>&1; then
  bad "Local.xcconfig is tracked; it holds a development team and must not be"
else
  ok "Local.xcconfig is untracked"
fi

step "Every published citation names a source"
# The disclaimer surface is load-bearing: it is what makes the advice checkable.
for needle in "Khalsa" "St Hilaire" "Zeitzer" "Burgess" "Meeus"; do
  if grep -q "$needle" App/Circadia/Support/DisclaimerView.swift; then
    ok "$needle"
  else
    bad "$needle missing from the in-app citations"
  fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31mChecks failed.\033[0m\n'; exit 1
fi
