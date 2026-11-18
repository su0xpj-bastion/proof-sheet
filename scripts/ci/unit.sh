#!/bin/bash
# ProofKit XCTest (39 workflow checks, client fault matrix, XCTest metrics) + the ps CLI.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
swift build -c debug --product ps
swift test --parallel=false 2>&1 | tee build/reports/swift-test.log
.build/debug/ps check
