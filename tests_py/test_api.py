"""Cloud contract tests: what the Swift client and the web page rely on, checked from outside."""
from __future__ import annotations

import hashlib
import time

import pytest


def upload(cloud, tok: str, data: bytes, aid: str = "a1", name: str = "a.jpg", kind: str = "photo", sha: str | None = None):
    chunk = 4096
    s, _, _ = cloud.call("POST", "/assets", {"id": aid, "name": name, "kind": kind, "size": len(data),
                                             "sha256": sha or hashlib.sha256(data).hexdigest(), "chunk_size": chunk}, tok)
    if s == 507:
        return s
    for i in range(0, len(data), chunk):
        cloud.call("PUT", f"/assets/{aid}/chunks/{i // chunk}", data[i:i + chunk], tok,
                   {"Content-Type": "application/octet-stream"})
    return cloud.call("POST", f"/assets/{aid}/commit", {}, tok)[0]


BLOB = bytes(range(256)) * 64


@pytest.mark.workflow("W24")
def test_commit_rejects_corrupt_upload(fresh):
    tok = fresh.token()
    assert upload(fresh, tok, BLOB, sha="0" * 64) == 422
    assert fresh.call("GET", "/assets", token=tok)[1] == []


@pytest.mark.workflow("W24")
def test_upload_status_lists_received_chunks(fresh):
    tok = fresh.token()
    fresh.call("POST", "/assets", {"id": "r1", "name": "r", "kind": "photo", "size": len(BLOB),
                                   "sha256": hashlib.sha256(BLOB).hexdigest(), "chunk_size": 4096}, tok)
    for i in (0, 1, 2):
        fresh.call("PUT", f"/assets/r1/chunks/{i}", BLOB[i * 4096:(i + 1) * 4096], tok)
    assert fresh.call("GET", "/assets/r1/upload", token=tok)[1]["received"] == [0, 1, 2]


@pytest.mark.workflow("W27")
def test_recipe_write_needs_matching_etag(fresh):
    tok = fresh.token()
    assert upload(fresh, tok, BLOB) == 200
    s, _, h = fresh.call("GET", "/assets/a1/recipe", token=tok)
    v0 = h["ETag"]
    assert fresh.call("PUT", "/assets/a1/recipe", {"recipe": {"exposure": 1}}, tok)[0] == 428
    assert fresh.call("PUT", "/assets/a1/recipe", {"recipe": {"exposure": 1}}, tok, {"If-Match": v0})[0] == 200
    s, body, h = fresh.call("PUT", "/assets/a1/recipe", {"recipe": {"exposure": 2}}, tok, {"If-Match": v0})
    assert s == 412 and h["ETag"] == '"v1"'


@pytest.mark.workflow("W28")
def test_recently_deleted_round_trip(fresh):
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    fresh.call("DELETE", "/assets/a1", token=tok)
    assert fresh.call("GET", "/assets", token=tok)[1] == []
    assert [a["id"] for a in fresh.call("GET", "/assets?deleted=1", token=tok)[1]] == ["a1"]
    fresh.call("POST", "/assets/a1/restore", token=tok)
    assert [a["id"] for a in fresh.call("GET", "/assets", token=tok)[1]] == ["a1"]


@pytest.mark.workflow("W29")
def test_quota_token_expiry_and_503(fresh):
    fresh.call("POST", "/_admin/config", {"quota": 100})
    tok = fresh.token()
    assert upload(fresh, tok, BLOB) == 507
    fresh.call("POST", "/_admin/config", {"quota": 10**9, "token_ttl": 0.1})
    tok = fresh.token()
    time.sleep(0.2)
    s, body, _ = fresh.call("GET", "/assets", token=tok)
    assert s == 401 and body["error"] == "token expired"
    fresh.call("POST", "/_admin/config", {"token_ttl": 3600, "flaky": 1})
    tok2 = fresh.call("POST", "/auth/token", {})
    assert tok2[0] == 503 and tok2[2]["Retry-After"] == "0"


@pytest.mark.workflow("W30")
def test_versions_and_restore(fresh):
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    tag = '"v0"'
    for ev in (0.5, 1.0):
        tag = fresh.call("PUT", "/assets/a1/recipe", {"recipe": {"exposure": ev}}, tok, {"If-Match": tag})[2]["ETag"]
    fresh.call("POST", "/assets/a1/versions/1/restore", token=tok)
    assert fresh.call("GET", "/assets/a1/recipe", token=tok)[1]["recipe"] == {"exposure": 0.5}
    assert [v["version"] for v in fresh.call("GET", "/assets/a1/versions", token=tok)[1]] == [0, 1, 2, 3]


@pytest.mark.workflow("W34")
def test_share_link_lifecycle(fresh):
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    share = fresh.call("POST", "/assets/a1/share", {}, tok)[1]["token"]
    assert fresh.call("GET", f"/s/{share}")[0] == 200
    fresh.call("DELETE", f"/share/{share}", token=tok)
    assert fresh.call("GET", f"/s/{share}")[0] == 404
    assert fresh.call("GET", f"/s/{share}/media")[0] == 404
    short = fresh.call("POST", "/assets/a1/share", {"expires_in": 0.1}, tok)[1]["token"]
    time.sleep(0.2)
    assert fresh.call("GET", f"/s/{short}")[0] == 410


@pytest.mark.workflow("W34")
def test_deleting_asset_kills_its_links(fresh):
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    share = fresh.call("POST", "/assets/a1/share", {}, tok)[1]["token"]
    fresh.call("DELETE", "/assets/a1", token=tok)
    assert fresh.call("GET", f"/s/{share}")[0] == 404


@pytest.mark.workflow("W35")
def test_media_variants(fresh):
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    share = fresh.call("POST", "/assets/a1/share", {}, tok)[1]["token"]
    # No rendition yet: "edited" falls back to the original rather than 404.
    assert fresh.call("GET", f"/s/{share}/media?variant=edited")[1] == BLOB
    fresh.call("PUT", "/assets/a1/rendition", b"EDITED", tok, {"Content-Type": "application/octet-stream"})
    s, body, h = fresh.call("GET", f"/s/{share}/media?variant=edited&download=1")
    assert body == b"EDITED" and h["Content-Disposition"].startswith("attachment")
    assert fresh.call("GET", f"/s/{share}/media?variant=original")[1] == BLOB


@pytest.mark.workflow("W31", "W35")
def test_media_supports_byte_ranges(fresh):
    """Safari refuses to play video from a server without 206 responses; Chrome cannot seek."""
    tok = fresh.token()
    upload(fresh, tok, BLOB)
    share = fresh.call("POST", "/assets/a1/share", {}, tok)[1]["token"]
    s, body, h = fresh.call("GET", f"/s/{share}/media", headers={"Range": "bytes=0-1"})
    assert s == 206 and body == BLOB[:2] and h["Content-Range"] == f"bytes 0-1/{len(BLOB)}"
    s, body, _ = fresh.call("GET", f"/s/{share}/media", headers={"Range": "bytes=-10"})
    assert s == 206 and body == BLOB[-10:]
    assert fresh.call("GET", f"/s/{share}/media", headers={"Range": f"bytes={len(BLOB)}-"})[0] == 416
