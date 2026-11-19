#!/bin/bash
# Cloud API contract + Selenium review-page tests + iPhone->Mac->web E2E.
# PROOF_BROWSER = safari | ios-safari | chrome (default chrome).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/ci/env.sh
mkdir -p build/reports
PY=${PYTHON:-python3}
[ -d .venv ] || $PY -m venv .venv
.venv/bin/pip -q install -r requirements-dev.txt
build_ps debug
.venv/bin/python -m pytest --junitxml="build/reports/pytest-${PROOF_BROWSER:-chrome}.xml" "$@"
