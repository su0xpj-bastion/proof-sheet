#!/bin/sh
# Every fault on, one at a time: each must fail exactly its pinned tests. Then workflow coverage.
set -eu
cd "$(dirname "$0")/../.."
PS=${PS_BIN:-.build/debug/ps}
[ -x "$PS" ] || swift build -c debug --product ps
.venv/bin/python tools/fault_matrix.py "$PS"
.venv/bin/python tools/workflow_coverage.py "$PS"
