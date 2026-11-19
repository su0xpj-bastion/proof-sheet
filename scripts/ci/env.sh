#!/bin/bash
# Sourced by the CI scripts. Detects whether this agent has Xcode, and builds `ps` the right way.
#   With Xcode: SwiftPM (swift build), XCTest and XCUITest available.
#   Without (Command Line Tools only): plain swiftc via scripts/build-local.sh; Xcode-only stages are
#   skipped and say so, instead of failing or pretending to pass.
if xcrun --find xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  HAS_XCODE=1
else
  HAS_XCODE=0
fi
export HAS_XCODE

build_ps() {   # build_ps [debug|release] -> sets PS_BIN
  local cfg=${1:-debug}
  if [ "$HAS_XCODE" = 1 ]; then
    swift build -c "$cfg" --product ps >&2
    PS_BIN=".build/$cfg/ps"
  else
    scripts/build-local.sh --build-only >&2
    PS_BIN=".build/local/ps"
  fi
  export PS_BIN
}
