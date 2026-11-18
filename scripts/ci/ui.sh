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
run() {  # run <result-name> [xcodebuild args...]
  local name=$1; shift
  rm -rf "build/reports/$name.xcresult"
  xcodebuild test -project App/ProofSheet.xcodeproj -scheme "$scheme" -destination "$dest" \
    -resultBundlePath "build/reports/$name.xcresult" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO "$@" \
    | tee "build/reports/$name.log" | grep -E "Test Case|error:|\*\* TEST|Executed"
}
run "ui-$1"
if [ "$1" != macos ]; then
  # W41 against the system setting: switch the simulator to dark and run that test alone.
  xcrun simctl ui "$udid" appearance dark
  TEST_RUNNER_PROOF_APPEARANCE=dark run "ui-$1-dark" -only-testing:ProofSheetUITests-iOS/ProofSheetUITests/test_W41_darkAppearance
  xcrun simctl ui "$udid" appearance light
fi
