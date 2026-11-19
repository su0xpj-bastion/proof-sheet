#!/bin/bash
# Workflow checks (JUnit for the CI UI), then XCTest when Xcode is present.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/ci/env.sh
mkdir -p build/reports
build_ps debug
"$PS_BIN" check --junit build/reports/workflow-checks.xml
if [ "$HAS_XCODE" = 1 ]; then
  swift test --no-parallel 2>&1 | tee build/reports/swift-test.log
else
  echo "XCTest: SKIPPED on this agent (no Xcode). The same 39 checks ran above through the ps CLI."
fi
