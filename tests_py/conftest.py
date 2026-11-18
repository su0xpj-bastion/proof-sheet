"""Shared fixtures: a live cloud/server.py, the Swift `ps` binary, and a Selenium driver.

Browser choice (PROOF_BROWSER):
  safari      macOS Safari via safaridriver (run `sudo safaridriver --enable` once)
  ios-safari  Safari in a booted iOS Simulator via safaridriver (needs Xcode)
  chrome      headless Chrome (default when Safari automation is unavailable; Linux Jenkins agents)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ENCODING = "utf-8"


class Cloud:
    def __init__(self, faults: str = "") -> None:
        env = dict(os.environ, PROOF_FAULTS=faults)
        self.proc = subprocess.Popen([sys.executable, str(ROOT / "cloud" / "server.py"), "--port", "0"],
                                     stdout=subprocess.PIPE, text=True, env=env)
        line = self.proc.stdout.readline()
        self.url = f"http://127.0.0.1:{int(line.split()[-1])}"

    def call(self, method: str, path: str, body: dict | bytes | None = None, token: str | None = None,
             headers: dict | None = None) -> tuple[int, dict | bytes, dict]:
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.url + path, data=data, method=method)
        if body is not None and not isinstance(body, bytes):
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                raw, status, hdrs = r.read(), r.status, dict(r.headers)
        except urllib.error.HTTPError as e:
            raw, status, hdrs = e.read(), e.code, dict(e.headers)
        try:
            return status, json.loads(raw) if raw else {}, hdrs
        except ValueError:
            return status, raw, hdrs

    def token(self) -> str:
        return self.call("POST", "/auth/token", {"device": "pytest"})[1]["token"]

    def reset(self) -> None:
        self.call("POST", "/_admin/reset", {})

    def stop(self) -> None:
        self.proc.terminate()
        self.proc.wait(timeout=5)


@pytest.fixture(scope="session")
def cloud():
    c = Cloud(os.environ.get("PROOF_FAULTS", ""))
    yield c
    c.stop()


@pytest.fixture()
def fresh(cloud):
    cloud.reset()
    return cloud


@pytest.fixture(scope="session")
def ps_bin() -> Path:
    """The Swift CLI, built with SwiftPM when available, else the Command Line Tools path."""
    for p in (ROOT / ".build" / "debug" / "ps", ROOT / ".build" / "release" / "ps", ROOT / ".build" / "local" / "ps"):
        if p.exists():
            return p
    subprocess.run([str(ROOT / "scripts" / "build-local.sh"), "--build-only"], check=True)
    return ROOT / ".build" / "local" / "ps"


def make_driver():
    from selenium import webdriver

    browser = os.environ.get("PROOF_BROWSER", "chrome")
    if browser == "safari":
        return webdriver.Safari()
    if browser == "ios-safari":
        opts = webdriver.SafariOptions()
        opts.set_capability("platformName", "iOS")
        opts.set_capability("safari:useSimulator", True)
        if os.environ.get("PROOF_SIM_DEVICE"):
            opts.set_capability("safari:deviceName", os.environ["PROOF_SIM_DEVICE"])
        return webdriver.Safari(options=opts)
    from selenium.webdriver.chrome.service import Service
    from selenium.webdriver.common.selenium_manager import SeleniumManager

    opts = webdriver.ChromeOptions()
    opts.add_argument("--headless=new")
    opts.add_argument("--window-size=1200,900")
    # A stale chromedriver on PATH is a classic CI break: ask Selenium Manager for one matching the installed Chrome.
    path = os.environ.get("PROOF_CHROMEDRIVER") or SeleniumManager().binary_paths(
        ["--browser", "chrome", "--skip-driver-in-path"])["driver_path"]
    return webdriver.Chrome(options=opts, service=Service(executable_path=path))


@pytest.fixture(scope="session")
def driver():
    d = make_driver()
    d.set_page_load_timeout(20)
    yield d
    d.quit()


def wait_for(fn, timeout: float = 8.0, interval: float = 0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception as e:  # element not there yet
            last = e
        time.sleep(interval)
    raise AssertionError(f"timed out waiting ({last})")


@pytest.fixture(scope="session")
def media(ps_bin) -> dict[str, Path]:
    """camera.jpg (1200x800, EXIF + GPS) and clip-h264.mp4 (90 frames), written by the Swift side."""
    work = Path(os.environ.get("PROOF_WORK", ROOT / ".build" / "proof-work"))
    out = subprocess.run([str(ps_bin), "fixtures", str(work)], check=True, capture_output=True, text=True).stdout.split()
    return {"photo": Path(out[0]), "video": Path(out[1])}


def device(ps_bin: Path, cloud: Cloud, name: str, *args: str) -> str:
    """Run one `ps device` action as a named device; returns its stdout."""
    r = subprocess.run([str(ps_bin), "device", cloud.url, name, *map(str, args)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout.strip()
