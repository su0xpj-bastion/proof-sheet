#!/bin/bash
# Every fault on, one at a time: each must fail exactly its pinned tests. Then workflow coverage.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/ci/env.sh
build_ps debug
[ -d .venv ] || { python3 -m venv .venv; .venv/bin/pip -q install -r requirements-dev.txt; }
.venv/bin/python tools/fault_matrix.py "$PS_BIN"
.venv/bin/python tools/workflow_coverage.py "$PS_BIN"
