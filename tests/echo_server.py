#!/usr/bin/env python3
"""Fake HTTP server for trying gooseman: echoes method, path, headers and body as JSON.

run: python3 tests/echo_server.py [port]   (default 8080)

Auth-protected routes (401 when credentials are wrong):
  /basic         Basic auth, user "gooseman" / password "secret"
  /bearer        Bearer token "static-token" or one issued by /oauth/token
  /apikey        header "X-API-Key: k3y" or query "?api_key=k3y"
  /cookie        cookie "session=s3ss"
  /login         POST {"user": "gooseman", "password": "secret"} -> sets the cookie, returns a fresh token
  /logout        revokes every token /login issued (simulates expiry)
  /jwt?ttl=N     POST -> {"token": <JWT expiring in N seconds>}, accepted by /bearer
  /oauth/token   POST form grant_type=client_credentials, client "cli" / "cli-secret"
                 (form fields or Basic auth) -> {"access_token": ...}
  /image         a 1x1 PNG (binary body)
  /events        Server-Sent Events: one "honk" per 0.7s, ?n= of them (default 5)
  /missing/...   always 404
"""
import base64
import itertools
import json
import sys
import time
import zlib
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TOKENS = {"static-token"}
ISSUED = itertools.count(1)


def basic(header, user, password):
    if not header.startswith("Basic "):
        return False
    try:
        return base64.b64decode(header[6:]).decode() == f"{user}:{password}"
    except ValueError:
        return False


class Echo(BaseHTTPRequestHandler):
    def reply(self, status, obj, headers=(), ctype="application/json"):
        out = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(out)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(out)

    def handle_one(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        auth = self.headers.get("Authorization", "")
        cookie = SimpleCookie(self.headers.get("Cookie", ""))

        if url.path == "/oauth/token":
            form = {k: v[0] for k, v in parse_qs(raw).items()}
            client_ok = basic(auth, "cli", "cli-secret") or (
                form.get("client_id") == "cli" and form.get("client_secret") == "cli-secret"
            )
            if form.get("grant_type") != "client_credentials" or not client_ok:
                return self.reply(401, {"error": "invalid_client"})
            token = f"oauth-{len(TOKENS)}"
            TOKENS.add(token)
            return self.reply(200, {"access_token": token, "token_type": "Bearer", "expires_in": 3600})

        if url.path == "/login":
            try:
                creds = json.loads(raw or "{}")
            except ValueError:
                creds = {}
            if creds != {"user": "gooseman", "password": "secret"}:
                return self.reply(401, {"error": "bad credentials"})
            token = f"login-{next(ISSUED)}"
            TOKENS.add(token)
            return self.reply(200, {"token": token}, [("Set-Cookie", "session=s3ss; HttpOnly")])

        if url.path == "/image":
            chunk = lambda kind, data: len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")
            png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", (1).to_bytes(4, "big") * 2 + b"\x08\x02\x00\x00\x00")
                   + chunk(b"IDAT", zlib.compress(b"\x00\xff\x88\x00")) + chunk(b"IEND", b""))
            return self.reply(200, png, ctype="image/png")

        if url.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for i in range(int(query.get("n", ["5"])[0])):
                self.wfile.write(f'id: {i}\ndata: {{"honk": {i}, "at": "{time.strftime("%H:%M:%S")}"}}\n\n'.encode())
                self.wfile.flush()
                time.sleep(0.7)
            return

        if url.path == "/jwt":
            ttl = int(query.get("ttl", ["3600"])[0])
            b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
            token = f'{b64({"alg": "none"})}.{b64({"sub": "gooseman", "n": next(ISSUED), "exp": int(time.time()) + ttl})}.'
            TOKENS.add(token)
            return self.reply(200, {"token": token})

        if url.path == "/logout":
            TOKENS.difference_update({t for t in TOKENS if t.startswith("login-")})
            return self.reply(200, {"revoked": True})

        checks = {
            "/basic": lambda: basic(auth, "gooseman", "secret"),
            "/bearer": lambda: auth.startswith("Bearer ") and auth[7:] in TOKENS,
            "/apikey": lambda: self.headers.get("X-API-Key") == "k3y" or query.get("api_key") == ["k3y"],
            "/cookie": lambda: "session" in cookie and cookie["session"].value == "s3ss",
        }
        if url.path in checks and not checks[url.path]():
            extra = [("WWW-Authenticate", 'Basic realm="gooseman"')] if url.path == "/basic" else []
            return self.reply(401, {"error": "unauthorized", "route": url.path}, extra)

        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        status = 404 if url.path.startswith("/missing") else 200
        self.reply(status, {"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_one


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"echo server on http://localhost:{port}")
    ThreadingHTTPServer(("127.0.0.1", port), Echo).serve_forever()
