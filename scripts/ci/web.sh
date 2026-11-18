#!/bin/sh
# Cloud API contract + Selenium review-page tests + iPhone->Mac->web E2E.
# PROOF_BROWSER = safari | ios-safari | chrome (default chrome).
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/reports
PY=${PYTHON:-python3}
[ -d .venv ] || $PY -m venv .venv
.venv/bin/pip -q install -r requirements-dev.txt
[ -x .build/debug/ps ] || swift build -c debug --product ps
.venv/bin/python -m pytest --junitxml="build/reports/pytest-${PROOF_BROWSER:-chrome}.xml" "$@"
