# Xcode Server bot (legacy, Xcode 9–12)

Recorded so a team still on an Xcode Server host can run this repo unchanged.

1. On the server Mac: Xcode ≤ 12 → Preferences → Server & Bots → enable; add the Jenkins/CI user.
2. Generate the project first (bots build whatever is checked in): `cd App && xcodegen`, commit `App/ProofSheet.xcodeproj`
   on a `xcode-server` branch, or add a pre-integration trigger that runs `xcodegen`.
3. Product → Create Bot… → scheme **ProofSheet-iOS**.
   - Integrate: on commit to `main`.
   - Actions: Analyze ✓, Test ✓, Archive ✗.
   - Test devices: "Specific iOS devices" → one iPhone and one iPad simulator (matches `scripts/ci/ui.sh ios-iphone|ios-ipad`).
   - Before integration trigger script: `cd "$XCS_PRIMARY_REPO_DIR/App" && xcodegen --quiet`
   - After integration trigger script: `"$XCS_PRIMARY_REPO_DIR/scripts/ci/matrix.sh"` (fault matrix + workflow coverage).
4. Second bot on **ProofSheet-macOS** (also runs `ProofKitTests`, the 39 workflow checks).

Integration results show per-test pass/fail and the screenshots attached by `ProofSheetUITests.tearDown`.
