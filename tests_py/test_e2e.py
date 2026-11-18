"""One edit travelling the whole system: iPhone -> cloud -> Mac -> web reviewer -> back to the iPhone.

The two devices are the Swift `ps` CLI with different device names (the same SyncClient and
Renderer the apps use); the reviewer is a real browser.
"""
from __future__ import annotations

import pytest
from selenium.webdriver.common.by import By

from conftest import device, wait_for


@pytest.mark.browser
@pytest.mark.workflow("W25", "W31", "W33")
def test_edit_on_iphone_review_on_web_status_back_on_iphone(driver, fresh, ps_bin, media, tmp_path):
    aid = device(ps_bin, fresh, "iphone", "upload", media["photo"])
    # iPhone crops on a 600x400 proxy: x 150..450, y 100..300  ->  the centre quarter of the full image.
    device(ps_bin, fresh, "iphone", "edit", aid, "0.3", "mono", 600, 400, 150, 100, 300, 200)
    out = tmp_path / "mac-render.jpg"
    device(ps_bin, fresh, "mac", "render", aid, out)
    share = device(ps_bin, fresh, "mac", "share", aid)

    driver.get(f"{fresh.url}/s/{share}")
    img = wait_for(lambda: driver.find_element(By.ID, "asset"))
    wait_for(lambda: driver.execute_script("return arguments[0].complete && arguments[0].naturalWidth", img))
    # The reviewer sees the Mac's full-resolution render of the iPhone's proxy crop.
    assert driver.execute_script("return [arguments[0].naturalWidth, arguments[0].naturalHeight]", img) == [600, 400]
    driver.find_element(By.ID, "approve").click()
    wait_for(lambda: driver.find_element(By.ID, "status").text == "approved")

    assert device(ps_bin, fresh, "iphone", "status", aid) == "approved"
