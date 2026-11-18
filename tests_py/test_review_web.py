"""The share-link review page, driven in a real browser with Selenium.

Safari on macOS, Safari in the iOS Simulator, or headless Chrome: see conftest.PROOF_BROWSER.
"""
from __future__ import annotations

import hashlib
import urllib.request

import pytest
from selenium.webdriver.common.actions.action_builder import ActionBuilder
from selenium.webdriver.common.by import By

from conftest import wait_for

pytestmark = pytest.mark.browser


def seed(cloud, path, kind="photo", aid="a1", **share):
    tok = cloud.token()
    data = path.read_bytes()
    cloud.call("POST", "/assets", {"id": aid, "name": path.name, "kind": kind, "size": len(data),
                                   "sha256": hashlib.sha256(data).hexdigest(), "chunk_size": len(data)}, tok)
    cloud.call("PUT", f"/assets/{aid}/chunks/0", data, tok, {"Content-Type": "application/octet-stream"})
    assert cloud.call("POST", f"/assets/{aid}/commit", {}, tok)[0] == 200
    share_tok = cloud.call("POST", f"/assets/{aid}/share", share, tok)[1]["token"]
    return tok, share_tok


def open_review(driver, cloud, share):
    driver.get(f"{cloud.url}/s/{share}")
    wait_for(lambda: driver.find_element(By.TAG_NAME, "body").get_attribute("data-ready") == "1")


@pytest.mark.workflow("W31")
def test_share_link_opens_review_page(driver, fresh, media):
    _, share = seed(fresh, media["photo"])
    open_review(driver, fresh, share)
    assert driver.title == "Review"
    assert driver.find_element(By.ID, "name").text == "camera.jpg"
    img = driver.find_element(By.ID, "asset")
    wait_for(lambda: driver.execute_script("return arguments[0].complete && arguments[0].naturalWidth", img))
    assert driver.execute_script("return [arguments[0].naturalWidth, arguments[0].naturalHeight]", img) == [1200, 800]
    assert driver.find_element(By.ID, "status").text == "pending"


@pytest.mark.workflow("W32")
def test_comment_pinned_to_photo_region(driver, fresh, media):
    _, share = seed(fresh, media["photo"])
    open_review(driver, fresh, share)
    img = driver.find_element(By.ID, "asset")
    wait_for(lambda: driver.execute_script("return arguments[0].naturalWidth", img))
    field = driver.find_element(By.ID, "comment-text")
    field.clear()
    field.send_keys("Lift the shadows here")
    # Click 25% across, 75% down, in viewport coordinates (element-relative offsets use the
    # "in-view centre", which moves when any part of the image is scrolled out).
    r = driver.execute_script("arguments[0].scrollIntoView({block: 'center'}); const r = arguments[0].getBoundingClientRect();"
                              "return [r.left, r.top, r.width, r.height]", img)
    actions = ActionBuilder(driver)
    actions.pointer_action.move_to_location(int(r[0] + r[2] * 0.25), int(r[1] + r[3] * 0.75)).click()
    actions.perform()
    pin = wait_for(lambda: driver.find_element(By.CSS_SELECTOR, "#pins .pin"))
    assert abs(float(pin.get_attribute("data-x")) - 0.25) < 0.02 and abs(float(pin.get_attribute("data-y")) - 0.75) < 0.02
    # Persisted: a reload shows the same pin, and the API has it.
    open_review(driver, fresh, share)
    assert wait_for(lambda: driver.find_elements(By.CSS_SELECTOR, "#comments li"))[0].text.endswith("Lift the shadows here")
    assert fresh.call("GET", f"/s/{share}/comments")[1][0]["text"] == "Lift the shadows here"


@pytest.mark.workflow("W32")
def test_comment_at_video_timecode(driver, fresh, media):
    _, share = seed(fresh, media["video"], kind="video")
    open_review(driver, fresh, share)
    video = driver.find_element(By.ID, "asset")
    if not wait_for(lambda: driver.execute_script("return arguments[0].readyState >= 1 || arguments[0].error !== null", video)) \
            or driver.execute_script("return arguments[0].error !== null", video):
        pytest.skip("this browser build cannot decode H.264 (open-source Chromium)")
    # Seek to frame 45 at 29.97 fps (1.5015 s) and comment there.
    driver.execute_script("arguments[0].currentTime = 45 * 1001 / 30000", video)
    wait_for(lambda: abs(driver.execute_script("return arguments[0].currentTime", video) - 1.5015) < 0.02)
    driver.find_element(By.ID, "comment-at-time").click()
    li = wait_for(lambda: driver.find_element(By.CSS_SELECTOR, "#comments li"))
    assert li.text.startswith("00:01:15"), li.text  # 45 frames = 1 s + 15 frames
    assert abs(fresh.call("GET", f"/s/{share}/comments")[1][0]["t"] - 1.5015) < 0.02


@pytest.mark.workflow("W33")
def test_approve_and_request_changes(driver, fresh, media):
    tok, share = seed(fresh, media["photo"])
    open_review(driver, fresh, share)
    driver.find_element(By.ID, "request-changes").click()
    wait_for(lambda: driver.find_element(By.ID, "status").text == "changes_requested")
    driver.find_element(By.ID, "approve").click()
    wait_for(lambda: driver.find_element(By.ID, "status").text == "approved")
    assert fresh.call("GET", "/assets/a1/recipe", token=tok)[1]["review"] == "approved"


@pytest.mark.workflow("W34")
def test_revoked_expired_and_password_links(driver, fresh, media):
    tok, share = seed(fresh, media["photo"])
    fresh.call("DELETE", f"/share/{share}", token=tok)
    driver.get(f"{fresh.url}/s/{share}")
    assert driver.find_element(By.ID, "gone").is_displayed()
    assert not driver.find_elements(By.ID, "asset")

    short = fresh.call("POST", "/assets/a1/share", {"expires_in": 0.2}, tok)[1]["token"]
    wait_for(lambda: fresh.call("GET", f"/s/{short}")[0] == 410)
    driver.get(f"{fresh.url}/s/{short}")
    assert driver.find_element(By.ID, "expired").is_displayed()

    locked = fresh.call("POST", "/assets/a1/share", {"password": "darkroom"}, tok)[1]["token"]
    driver.get(f"{fresh.url}/s/{locked}")
    assert not driver.find_elements(By.ID, "asset")
    driver.find_element(By.ID, "password").send_keys("wrong")
    driver.find_element(By.ID, "unlock").click()
    assert wait_for(lambda: driver.find_element(By.ID, "wrong-password")).is_displayed()
    driver.find_element(By.ID, "password").send_keys("darkroom")
    driver.find_element(By.ID, "unlock").click()
    wait_for(lambda: driver.find_element(By.ID, "asset"))


@pytest.mark.workflow("W35")
def test_download_links_serve_exact_bytes(driver, fresh, media):
    tok, share = seed(fresh, media["photo"])
    fresh.call("PUT", "/assets/a1/rendition", b"edited-bytes", tok, {"Content-Type": "application/octet-stream"})
    open_review(driver, fresh, share)
    got = {}
    for which in ("original", "edited"):
        href = driver.find_element(By.ID, f"download-{which}").get_attribute("href")
        with urllib.request.urlopen(href) as r:
            got[which] = (r.read(), r.headers["Content-Disposition"])
    assert hashlib.sha256(got["original"][0]).hexdigest() == hashlib.sha256(media["photo"].read_bytes()).hexdigest()
    assert got["edited"][0] == b"edited-bytes"
    assert all(d.startswith("attachment") for _, d in got.values())
