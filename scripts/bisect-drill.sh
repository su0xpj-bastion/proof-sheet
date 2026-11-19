#!/bin/bash
# Regression-isolation drill: re-introduce a real bug from this project's history (the HDR
# threshold that made SDR JPEG exports tone-map and go dark) inside 8 ordinary commits in a
# throwaway clone, then let `git bisect run` find the commit with the workflow checks as the oracle.
# Usage: scripts/bisect-drill.sh            (leaves the repo untouched)
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bisect-drill.XXXXXX")
git clone -q . "$WORK/repo"
cd "$WORK/repo"
git config user.email drill@example.invalid
git config user.name "bisect drill"
GOOD=$(git rev-parse HEAD)
for i in 1 2 3 4 5 6 7 8; do
  if [ "$i" = 5 ]; then
    # The regression: "tighten" HDR detection back to 1.001. JPEG decode overshoots 1.0 by ~1%,
    # so ordinary photos get tone-mapped.
    sed -i '' 's/public static let hdrThreshold: Float = 1.05/public static let hdrThreshold: Float = 1.001/' Sources/ProofKit/PhotoIO.swift
    git commit -qam "PhotoIO: tighten HDR detection threshold"
  else
    echo "// drill change $i" >> Sources/ProofKit/Recipe.swift
    git commit -qam "Recipe: housekeeping $i"
  fi
done
BAD=$(git rev-parse HEAD)
echo "good $GOOD"
echo "bad  $BAD  (8 commits later)"
git bisect start "$BAD" "$GOOD" >/dev/null
# Oracle: the two workflow checks that caught this bug the first time. Exit 0 good, 1 bad.
git bisect run sh -c 'BUILD_DIR=.build/drill scripts/build-local.sh check import.orientation color.p3-gamut >/dev/null 2>&1' | grep -E "is the first bad commit|^commit|PhotoIO|bisect found" || true
git bisect log | grep -E "^# (good|bad|first bad)" 
git bisect reset >/dev/null
echo "drill workspace: $WORK"
