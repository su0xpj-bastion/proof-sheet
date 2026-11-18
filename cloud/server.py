"""proof-sheet cloud: a small, stdlib-only stand-in for a photo/video sync + review service.

Run:  python3 cloud/server.py --port 8765        (--port 0 picks a free port and prints it)

It implements the contract the Swift SyncClient and the web review page rely on: token auth,
chunked resumable upload with a SHA-256 commit, recipe versions guarded by ETag/If-Match,
Recently Deleted, conflict duplicates, share links (expiry, password, revoke), comments and
review status. Faults from PROOF_FAULTS (comma separated) break it on purpose.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import secrets
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FAULTS = {f for f in os.environ.get("PROOF_FAULTS", "").split(",") if f}
WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")


def fault(name: str) -> bool:
    return name in FAULTS


class State:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.reset()

    def reset(self) -> None:
        self.tokens: dict[str, float] = {}          # token -> expiry
        self.token_ttl = 3600.0
        self.quota = 512 * 1024 * 1024
        self.flaky = 0                               # next N requests answer 503
        self.assets: dict[str, dict] = {}
        self.uploads: dict[str, dict] = {}
        self.shares: dict[str, dict] = {}
        self.requests = 0

    def used(self) -> int:
        return sum(a["size"] for a in self.assets.values())


STATE = State()


def etag(version: int) -> str:
    return f'"v{version}"'


class Handler(BaseHTTPRequestHandler):
    server_version = "proof-sheet/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # quiet unless asked
        if os.environ.get("PROOF_SERVER_LOG"):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # ---- plumbing -------------------------------------------------------------------------
    def body(self) -> bytes:
        # Read exactly once per request: an unread body would be parsed as the next request on keep-alive.
        if not hasattr(self, "_body") or self._body_for is not self.requestline:
            n = int(self.headers.get("Content-Length") or 0)
            self._body = self.rfile.read(n) if n else b""
            self._body_for = self.requestline
        return self._body

    def json_body(self) -> dict:
        raw = self.body()
        return json.loads(raw) if raw else {}

    def send(self, status: int, payload=None, headers: dict | None = None, ctype: str = "application/json") -> None:
        if isinstance(payload, (dict, list)):
            data = json.dumps(payload).encode()
        elif isinstance(payload, str):
            data = payload.encode()
        else:
            data = payload or b""
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def authed(self) -> bool:
        auth = self.headers.get("Authorization", "")
        tok = auth[7:] if auth.startswith("Bearer ") else ""
        with STATE.lock:
            exp = STATE.tokens.get(tok)
        if exp is None or exp < time.time():
            self.send(401, {"error": "token expired" if exp else "unauthorized"})
            return False
        return True

    def route(self, method: str) -> None:
        self._body_for = None
        self.body()
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        if path.startswith("/_admin/"):
            return self.admin(path, method)
        with STATE.lock:
            STATE.requests += 1
            if STATE.flaky > 0:
                STATE.flaky -= 1
                return self.send(503, {"error": "try again"}, {"Retry-After": "0"})
        if path.startswith("/s/") or path.startswith("/web/"):
            return self.review(method, path, query)
        if path == "/auth/token" and method == "POST":
            tok = secrets.token_hex(16)
            with STATE.lock:
                STATE.tokens[tok] = time.time() + STATE.token_ttl
            return self.send(200, {"token": tok, "expires_in": STATE.token_ttl})
        if not self.authed():
            return
        for pattern, fn in ROUTES:
            m = re.fullmatch(pattern[1], path)
            if m and pattern[0] == method:
                return fn(self, *m.groups(), query=query)
        self.send(404, {"error": "no route"})

    def do_GET(self) -> None:
        self.route("GET")

    def do_POST(self) -> None:
        self.route("POST")

    def do_PUT(self) -> None:
        self.route("PUT")

    def do_DELETE(self) -> None:
        self.route("DELETE")

    # ---- admin (tests only) -----------------------------------------------------------------
    def admin(self, path: str, method: str) -> None:
        if path == "/_admin/reset":
            STATE.reset()
            return self.send(200, {"ok": True})
        if path == "/_admin/config" and method == "POST":
            cfg = self.json_body()
            with STATE.lock:
                for k in ("quota", "token_ttl", "flaky"):
                    if k in cfg:
                        setattr(STATE, k, cfg[k])
            return self.send(200, {"ok": True})
        if path == "/_admin/stats":
            return self.send(200, {"requests": STATE.requests, "used": STATE.used(), "faults": sorted(FAULTS)})
        self.send(404, {"error": "no admin route"})

    # ---- assets -----------------------------------------------------------------------------
    def asset(self, aid: str) -> dict | None:
        a = STATE.assets.get(aid)
        if a is None:
            self.send(404, {"error": "no such asset"})
        return a

    def create_upload(self, query) -> None:
        d = self.json_body()
        with STATE.lock:
            if d["id"] in STATE.assets:
                return self.send(200, {"id": d["id"], "existing": True})
            if STATE.used() + d["size"] > STATE.quota:
                return self.send(507, {"error": "iCloud-style storage full", "used": STATE.used(), "quota": STATE.quota})
            up = STATE.uploads.setdefault(d["id"], {"meta": d, "chunks": {}})
            up["meta"] = d
        self.send(201, {"id": d["id"], "chunk_size": d["chunk_size"]})

    def put_chunk(self, aid: str, n: str, query) -> None:
        data = self.body()
        with STATE.lock:
            up = STATE.uploads.get(aid)
            if up is None:
                return self.send(404, {"error": "no upload"})
            up["chunks"][int(n)] = data
        self.send(204)

    def upload_status(self, aid: str, query) -> None:
        with STATE.lock:
            up = STATE.uploads.get(aid)
            received = [] if up is None or fault("uploadNotResumable") else sorted(up["chunks"])
        self.send(200, {"received": received})

    def commit(self, aid: str, query) -> None:
        with STATE.lock:
            up = STATE.uploads.get(aid)
            if up is None:
                return self.send(404, {"error": "no upload"})
            meta = up["meta"]
            blob = b"".join(up["chunks"][i] for i in sorted(up["chunks"]))
            if hashlib.sha256(blob).hexdigest() != meta["sha256"] or len(blob) != meta["size"]:
                return self.send(422, {"error": "checksum mismatch", "got": len(blob)})
            STATE.assets[aid] = {
                "id": aid, "name": meta["name"], "kind": meta["kind"], "size": len(blob), "original": blob,
                "rendition": None, "versions": [{"version": 0, "recipe": None, "device": meta.get("device")}],
                "deleted": False, "review": "pending", "comments": [],
            }
            del STATE.uploads[aid]
        self.send(200, {"id": aid, "etag": etag(0)})

    def list_assets(self, query) -> None:
        deleted = query.get("deleted", ["0"])[0] == "1"
        with STATE.lock:
            rows = [{"id": a["id"], "name": a["name"], "kind": a["kind"], "etag": etag(a["versions"][-1]["version"]),
                     "review": a["review"]} for a in STATE.assets.values() if a["deleted"] == deleted]
        self.send(200, rows)

    def original(self, aid: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            self.send(200, a["original"], ctype="application/octet-stream")

    def put_rendition(self, aid: str, query) -> None:
        data = self.body()
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            a["rendition"] = data
        self.send(204)

    def get_recipe(self, aid: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            v = a["versions"][-1]
        self.send(200, {"recipe": v["recipe"], "version": v["version"], "review": a["review"]}, {"ETag": etag(v["version"])})

    def put_recipe(self, aid: str, query) -> None:
        d = self.json_body()
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            current = etag(a["versions"][-1]["version"])
            match = self.headers.get("If-Match")
            if match is None and not fault("conflictSilentOverwrite"):
                return self.send(428, {"error": "If-Match required"})
            if match != current and not fault("conflictSilentOverwrite"):
                return self.send(412, {"error": "conflict", "current": current}, {"ETag": current})
            n = a["versions"][-1]["version"] + 1
            a["versions"].append({"version": n, "recipe": d.get("recipe"), "device": d.get("device")})
        self.send(200, {"version": n}, {"ETag": etag(n)})

    def versions(self, aid: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            self.send(200, [{"version": v["version"], "device": v["device"], "recipe": v["recipe"]} for v in a["versions"]])

    def restore_version(self, aid: str, n: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            old = next((v for v in a["versions"] if v["version"] == int(n)), None)
            if old is None:
                return self.send(404, {"error": "no such version"})
            new = a["versions"][-1]["version"] + 1
            a["versions"].append({"version": new, "recipe": old["recipe"], "device": "restore"})
        self.send(200, {"version": new}, {"ETag": etag(new)})

    def duplicate(self, aid: str, query) -> None:
        d = self.json_body()
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            k = 1
            while f"{aid}-copy{k}" in STATE.assets:
                k += 1
            nid = f"{aid}-copy{k}"
            STATE.assets[nid] = dict(a, id=nid, name=f"{a['name']} (conflict copy)", comments=[], review="pending",
                                     versions=[{"version": 0, "recipe": None, "device": None},
                                               {"version": 1, "recipe": d.get("recipe"), "device": d.get("device")}])
        self.send(201, {"id": nid, "etag": etag(1)})

    def delete(self, aid: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            a["deleted"] = True
        self.send(204)

    def restore(self, aid: str, query) -> None:
        with STATE.lock:
            a = self.asset(aid)
            if a is None:
                return
            a["deleted"] = False
        self.send(204)

    # ---- sharing + review -------------------------------------------------------------------
    def create_share(self, aid: str, query) -> None:
        d = self.json_body()
        with STATE.lock:
            if self.asset(aid) is None:
                return
            tok = secrets.token_urlsafe(9)
            exp = d.get("expires_in")
            STATE.shares[tok] = {"asset": aid, "expires": time.time() + exp if exp else None,
                                 "password": d.get("password"), "revoked": False, "unlock": secrets.token_hex(8)}
        self.send(201, {"token": tok, "url": f"/s/{tok}"})

    def revoke_share(self, tok: str, query) -> None:
        with STATE.lock:
            s = STATE.shares.get(tok)
            if s is None:
                return self.send(404, {"error": "no share"})
            s["revoked"] = True
        self.send(204)

    def share_for(self, tok: str) -> tuple[dict | None, dict | None]:
        """(share, asset) if the link may serve, else sends the right error page and returns Nones."""
        s = STATE.shares.get(tok)
        if s is None or (s["revoked"] and not fault("revokedLinkStillServes")):
            self.send(404, page("Link not available", "<p id='gone'>This link was turned off by its owner.</p>"),
                      ctype="text/html; charset=utf-8")
            return None, None
        if s["expires"] is not None and s["expires"] < time.time():
            self.send(410, page("Link expired", "<p id='expired'>This link has expired.</p>"), ctype="text/html; charset=utf-8")
            return None, None
        a = STATE.assets.get(s["asset"])
        if a is None or a["deleted"]:
            self.send(404, page("Link not available", "<p id='gone'>This item was deleted.</p>"), ctype="text/html; charset=utf-8")
            return None, None
        return s, a

    def unlocked(self, s: dict) -> bool:
        if not s["password"]:
            return True
        return f"unlock={s['unlock']}" in (self.headers.get("Cookie") or "")

    def review(self, method: str, path: str, query) -> None:
        if path.startswith("/web/"):
            name = os.path.basename(path)
            fp = os.path.join(WEB, name)
            if not os.path.isfile(fp):
                return self.send(404, {"error": "no file"})
            with open(fp, "rb") as f:
                ctype = "text/javascript" if name.endswith(".js") else "text/css"
                return self.send(200, f.read(), ctype=ctype)
        m = re.fullmatch(r"/s/([\w-]+)(/[\w-]+)?", path)
        if not m:
            return self.send(404, {"error": "no route"})
        tok, sub = m.group(1), m.group(2) or ""
        with STATE.lock:
            s, a = self.share_for(tok)
            if s is None:
                return
            if sub == "/unlock" and method == "POST":
                form = parse_qs(self.body().decode())
                if form.get("password", [""])[0] == s["password"]:
                    return self.send(303, b"", {"Location": f"/s/{tok}", "Set-Cookie": f"unlock={s['unlock']}; Path=/s/{tok}; HttpOnly"})
                return self.send(401, lock_page(tok, wrong=True), ctype="text/html; charset=utf-8")
            if not self.unlocked(s):
                return self.send(401, lock_page(tok), ctype="text/html; charset=utf-8")
            if sub == "" and method == "GET":
                return self.send(200, review_page(tok, a), ctype="text/html; charset=utf-8")
            if sub == "/media" and method == "GET":
                variant = query.get("variant", ["edited"])[0]
                data = a["rendition"] if variant == "edited" and a["rendition"] else a["original"]
                # Review copies of video are H.264 MP4: the one format every browser on every platform plays.
                ext = "mp4" if a["kind"] == "video" else "jpg"
                disp = "attachment" if query.get("download") else "inline"
                ctype = "video/mp4" if a["kind"] == "video" else "image/jpeg"
                headers = {"Content-Disposition": f'{disp}; filename="{a["id"]}-{variant}.{ext}"', "Accept-Ranges": "bytes"}
                # Byte ranges: without 206 responses Safari will not play video at all and Chrome cannot seek.
                rng = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
                if rng and (rng.group(1) or rng.group(2)):
                    n = len(data)
                    if rng.group(1):
                        start = int(rng.group(1))
                        end = min(int(rng.group(2)), n - 1) if rng.group(2) else n - 1
                    else:
                        start, end = max(0, n - int(rng.group(2))), n - 1
                    if start >= n or start > end:
                        return self.send(416, b"", {"Content-Range": f"bytes */{n}"})
                    headers["Content-Range"] = f"bytes {start}-{end}/{n}"
                    return self.send(206, data[start:end + 1], headers, ctype=ctype)
                return self.send(200, data, headers, ctype=ctype)
            if sub == "/comments":
                if method == "POST":
                    c = self.json_body()
                    c = {k: c[k] for k in ("text", "x", "y", "t") if k in c}
                    a["comments"].append(c)
                    return self.send(201, c)
                return self.send(200, a["comments"])
            if sub == "/status" and method == "POST":
                st = self.json_body().get("status")
                if st not in ("approved", "changes_requested"):
                    return self.send(400, {"error": "bad status"})
                a["review"] = st
                return self.send(200, {"status": st})
        self.send(404, {"error": "no route"})


def page(title: str, body: str) -> str:
    return (f"<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>{html.escape(title)}</title><link rel='stylesheet' href='/web/review.css'></head><body><main>"
            f"<h1>{html.escape(title)}</h1>{body}</main></body></html>")


def lock_page(tok: str, wrong: bool = False) -> str:
    err = "<p id='wrong-password' role='alert'>Wrong password.</p>" if wrong else ""
    return page("Password required", f"{err}<form method='post' action='/s/{tok}/unlock'>"
                "<label for='password'>Password</label><input id='password' name='password' type='password' autocomplete='off'>"
                "<button id='unlock' type='submit'>View</button></form>")


def review_page(tok: str, a: dict) -> str:
    if a["kind"] == "video":
        media = (f"<video id='asset' src='/s/{tok}/media?variant=edited' controls playsinline muted preload='auto'></video>"
                 "<button id='comment-at-time' type='button'>Comment at playhead</button>")
    else:
        media = f"<div id='stage'><img id='asset' src='/s/{tok}/media?variant=edited' alt='{html.escape(a['name'])}'><div id='pins'></div></div>"
    body = (f"<p id='name'>{html.escape(a['name'])}</p>{media}"
            "<label for='comment-text'>Comment</label><input id='comment-text' value='Looks good'>"
            "<ol id='comments' aria-label='Comments'></ol>"
            f"<p>Status: <strong id='status'>{html.escape(a['review'])}</strong></p>"
            "<button id='approve' type='button'>Approve</button> <button id='request-changes' type='button'>Request changes</button>"
            f"<p><a id='download-original' href='/s/{tok}/media?variant=original&download=1'>Download original</a> · "
            f"<a id='download-edited' href='/s/{tok}/media?variant=edited&download=1'>Download edited</a></p>"
            f"<script>window.SHARE={json.dumps(tok)};window.KIND={json.dumps(a['kind'])};</script><script src='/web/review.js'></script>")
    return page("Review", body)


R = Handler
ROUTES = [
    (("POST", r"/assets"), R.create_upload),
    (("GET", r"/assets"), R.list_assets),
    (("PUT", r"/assets/([\w-]+)/chunks/(\d+)"), R.put_chunk),
    (("GET", r"/assets/([\w-]+)/upload"), R.upload_status),
    (("POST", r"/assets/([\w-]+)/commit"), R.commit),
    (("GET", r"/assets/([\w-]+)/original"), R.original),
    (("PUT", r"/assets/([\w-]+)/rendition"), R.put_rendition),
    (("GET", r"/assets/([\w-]+)/recipe"), R.get_recipe),
    (("PUT", r"/assets/([\w-]+)/recipe"), R.put_recipe),
    (("GET", r"/assets/([\w-]+)/versions"), R.versions),
    (("POST", r"/assets/([\w-]+)/versions/(\d+)/restore"), R.restore_version),
    (("POST", r"/assets/([\w-]+)/duplicate"), R.duplicate),
    (("DELETE", r"/assets/([\w-]+)"), R.delete),
    (("POST", r"/assets/([\w-]+)/restore"), R.restore),
    (("POST", r"/assets/([\w-]+)/share"), R.create_share),
    (("DELETE", r"/share/([\w-]+)"), R.revoke_share),
]


def serve(port: int) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    return httpd


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    httpd = serve(args.port)
    print(f"LISTENING {httpd.server_address[1]}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
