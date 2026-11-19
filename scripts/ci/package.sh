#!/bin/bash
# Delivery: a versioned, checksummed release bundle that a later stage (or a person) can promote.
#   dist/proof-sheet-<version>+<build>.<sha>.tar.gz   ps CLI, cloud service, docs, test reports, manifest
#   With Xcode, also an unsigned archive of the macOS app (signing and notarization need a team identity).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/ci/env.sh
VERSION=$(grep -m1 'CFBundleShortVersionString' App/project.yml | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=${BUILD_NUMBER:-local}
SHA=$(git rev-parse --short HEAD)
NAME="proof-sheet-${VERSION}+${BUILD}.${SHA}"
OUT="dist/$NAME"
rm -rf dist && mkdir -p "$OUT"
build_ps release 2>/dev/null || build_ps debug
cp "$PS_BIN" "$OUT/ps"
cp -R cloud "$OUT/cloud"
cp -R docs WORKFLOWS.md BUGS.md README.md "$OUT/"
[ -d build/reports ] && cp -R build/reports "$OUT/test-reports" || true
if [ "$HAS_XCODE" = 1 ]; then
  which xcodegen >/dev/null || brew install xcodegen
  (cd App && xcodegen --quiet)
  xcodebuild archive -project App/ProofSheet.xcodeproj -scheme ProofSheet-macOS -archivePath "$OUT/ProofSheet.xcarchive" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO | tail -3
  APP_ARCHIVE="ProofSheet.xcarchive (unsigned)"
else
  APP_ARCHIVE="skipped: no Xcode on this agent"
fi
CHECKS=$( (grep -o 'tests="[0-9]*"' build/reports/workflow-checks.xml 2>/dev/null || true) | head -1 | tr -dc 0-9)
FAILS=$( (grep -o 'failures="[0-9]*"' build/reports/workflow-checks.xml 2>/dev/null || true) | head -1 | tr -dc 0-9)
cat > "$OUT/manifest.json" <<JSON
{
  "name": "proof-sheet",
  "version": "$VERSION",
  "build": "$BUILD",
  "commit": "$(git rev-parse HEAD)",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "agent_has_xcode": $HAS_XCODE,
  "workflow_checks": {"tests": ${CHECKS:-0}, "failures": ${FAILS:-0}},
  "app_archive": "$APP_ARCHIVE"
}
JSON
tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
(cd dist && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "packaged dist/$NAME.tar.gz"
cat "dist/$NAME.tar.gz.sha256"
