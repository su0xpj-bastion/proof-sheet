#!/bin/bash
# XCUITest via xcodebuild. Usage: ui.sh ios-iphone | ios-ipad | macos
set -euo pipefail
cd "$(dirname "$0")/../.."
which xcodegen >/dev/null || brew install xcodegen
(cd App && xcodegen --quiet)
mkdir -p build/reports
case "$1" in
  ios-iphone|ios-ipad)
    kind=${1#ios-}
    udid=$(python3 scripts/ci/pick-sim.py "$kind")
    xcrun simctl boot "$udid" || true
    dest="id=$udid"; scheme=ProofSheet-iOS ;;
  macos)
    dest="platform=macOS"; scheme=ProofSheet-macOS ;;
  *) echo "usage: $0 ios-iphone|ios-ipad|macos"; exit 2 ;;
esac
rm -rf "build/reports/ui-$1.xcresult"
xcodebuild test -project App/ProofSheet.xcodeproj -scheme "$scheme" -destination "$dest" \
  -resultBundlePath "build/reports/ui-$1.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  | tee "build/reports/ui-$1.log" | grep -E "Test Case|error:|\*\* TEST|Executed" 
