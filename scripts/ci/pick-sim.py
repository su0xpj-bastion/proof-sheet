"""Print the UDID of the newest available simulator of a kind (iphone | ipad), booting nothing."""
from __future__ import annotations

import json
import re
import subprocess
import sys

kind = sys.argv[1] if len(sys.argv) > 1 else "iphone"
data = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], check=True,
                                 capture_output=True, text=True).stdout)
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"].lower()
        if name.startswith(kind) and "se" not in name.split():
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"])
if best is None:
    sys.exit(f"no {kind} simulator")
print(best[1])
