"""Turn on each fault and prove the suites catch it: the set of failing tests must equal the pinned set.

Swift side: expectations pinned in Sources/ProofChecks/Checks.swift (read via `ps json`).
Python side: expectations pinned below. Server-side faults run both suites.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PYTEST_EXPECTED: dict[str, set[str]] = {
    "uploadNotResumable": {"tests_py/test_api.py::test_upload_status_lists_received_chunks"},
    "conflictSilentOverwrite": {"tests_py/test_api.py::test_recipe_write_needs_matching_etag"},
    "revokedLinkStillServes": {"tests_py/test_api.py::test_share_link_lifecycle",
                               "tests_py/test_review_web.py::test_revoked_expired_and_password_links"},
}


def run_ps(ps: str, fault: str) -> set[str]:
    out = subprocess.run([ps, "failing"], capture_output=True, text=True, env=dict(os.environ, PROOF_FAULTS=fault)).stdout
    return set(re.findall(r"^FAILED (\S+)", out, re.M))


def run_pytest(fault: str, browser: bool) -> set[str]:
    args = [sys.executable, "-m", "pytest", "-q", "-rf", "-p", "no:cacheprovider"] + ([] if browser else ["-m", "not browser"])
    out = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, PROOF_FAULTS=fault)).stdout
    return set(re.findall(r"^FAILED (\S+?)(?: - |$)", out, re.M))


def main() -> int:
    ps = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build" / "local" / "ps")
    browser = os.environ.get("PROOF_MATRIX_BROWSER", "1") == "1"
    data = json.loads(subprocess.run([ps, "json"], check=True, capture_output=True, text=True).stdout)
    swift_expected = {k: set(v) for k, v in data["expectedFailures"].items()}
    ok = True
    for fault in sorted(swift_expected):
        got = run_ps(ps, fault)
        rows = [("swift", got, swift_expected[fault])]
        if fault in PYTEST_EXPECTED:
            want = PYTEST_EXPECTED[fault] if browser else {t for t in PYTEST_EXPECTED[fault] if "review_web" not in t}
            rows.append(("pytest", run_pytest(fault, browser), want))
        for layer, got, want in rows:
            good = got == want
            ok &= good
            print(f"{'ok ' if good else 'BAD'} {fault:26} {layer:6} caught by {sorted(got) or '-'}")
            if not good:
                print(f"      expected {sorted(want)}")
    print("\nfault matrix: " + ("every fault caught by exactly its pinned tests" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
