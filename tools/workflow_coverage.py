"""Fail if any workflow in WORKFLOWS.md has no test; print the coverage matrix.

Sources of coverage:
  swift   `ps json`: each check's workflow tags (run as XCTest on CI, `ps check` locally)
  pytest  @pytest.mark.workflow("Wnn", ...) in tests_py/
  xcui    XCUITest methods named test_Wnn_... in App/UITests/
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENCODING = "utf-8"


def workflows() -> dict[str, str]:
    rows = re.findall(r"^\| (W\d\d) \| (.+?) \|", (ROOT / "WORKFLOWS.md").open("r", encoding=ENCODING).read(), re.M)
    return dict(rows)


def swift(ps: str) -> dict[str, set[str]]:
    data = json.loads(subprocess.run([ps, "json"], check=True, capture_output=True, text=True).stdout)
    out: dict[str, set[str]] = {}
    for c in data["checks"]:
        for w in c["workflows"]:
            out.setdefault(w, set()).add(c["name"])
    return out


def pytest_marks() -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for f in sorted((ROOT / "tests_py").glob("test_*.py")):
        text = f.open("r", encoding=ENCODING).read()
        for marks, name in re.findall(r'((?:@pytest\.mark\.workflow\([^)]*\)\s*(?:@[^\n]*\s*)*)+)def (test_\w+)', text):
            for w in re.findall(r"W\d\d", marks):
                out.setdefault(w, set()).add(f"{f.stem}::{name}")
    return out


def xcui() -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for f in sorted((ROOT / "App" / "UITests").glob("*.swift")):
        for m in re.finditer(r"func (test_((?:W\d\d_?)+)\w*)\(", f.open("r", encoding=ENCODING).read()):
            for w in re.findall(r"W\d\d", m.group(2)):
                out.setdefault(w, set()).add(m.group(1))
    return out


def main() -> int:
    ps = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build" / "local" / "ps")
    wf, layers = workflows(), {"swift": swift(ps), "pytest": pytest_marks(), "xcui": xcui()}
    missing = []
    print(f"{'ID':4} {'swift':>5} {'pytest':>6} {'xcui':>4}  workflow")
    for wid, title in wf.items():
        counts = [len(layers[k].get(wid, ())) for k in ("swift", "pytest", "xcui")]
        if not any(counts):
            missing.append(wid)
        print(f"{wid:4} {counts[0]:>5} {counts[1]:>6} {counts[2]:>4}  {title}{'   <-- NOT COVERED' if not any(counts) else ''}")
    unknown = sorted(set().union(*[set(v) for v in layers.values()]) - set(wf))
    if unknown:
        print(f"tests tag unknown workflows: {unknown}")
    total = len(wf)
    print(f"\n{total - len(missing)}/{total} workflows covered")
    return 1 if missing or unknown else 0


if __name__ == "__main__":
    sys.exit(main())
