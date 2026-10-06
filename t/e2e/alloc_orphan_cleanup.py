#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026-present Lightbits Labs Ltd.
#
# Fault-injecting reverse proxy for t/e2e/alloc_orphan_cleanup.sh.
#
# Sits between the plugin and a real LightOS API endpoint and forwards
# everything verbatim — except GETs for a single volume (the state poll
# alloc_image does after creation), which it answers with an injected 503 or
# 404 without contacting the cluster. Volume creation and deletion still hit
# the real cluster, so the plugin's orphan cleanup is exercised against real
# state, deterministically: the poll always fails, no timing window involved.
#
# Every proxied/injected request is appended to --log as "METHOD PATH -> CODE"
# so the test can assert what the plugin actually did (e.g. that the DELETE it
# issued targeted the volume the POST created).
#
# Usage:
#   alloc_orphan_cleanup.py --listen-port 8443 --upstream 192.168.20.237:443 \
#       --cert /tmp/cert.pem --key /tmp/key.pem --inject 503 --log /tmp/proxy.log
import argparse
import http.server
import re
import ssl
import urllib.request

VOLUME_GET = re.compile(r"^/api/v2/volumes/[0-9a-f-]{36}(\?|$)", re.I)

args = None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _record(self, code):
        with open(args.log, "a") as f:
            f.write(f"{self.command} {self.path} -> {code}\n")

    def _respond(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        if self.command == "GET" and VOLUME_GET.match(self.path):
            self._record(f"INJECTED-{args.inject}")
            self._respond(args.inject, b'{"error": "injected by alloc_orphan_cleanup.py"}')
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        url = f"https://{args.upstream}{self.path}"
        req = urllib.request.Request(url, data=body, method=self.command)
        for h in ("Authorization", "Content-Type"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
                out, code = r.read(), r.status
        except urllib.error.HTTPError as e:
            out, code = e.read(), e.code
        # Tag volume-creation responses with the UUID the cluster assigned, so
        # the test can assert the plugin's cleanup DELETE targets that volume.
        tag = ""
        if self.command == "POST" and self.path.startswith("/api/v2/volumes"):
            m = re.search(rb'"UUID"\s*:\s*"([0-9a-f-]{36})"', out)
            if m:
                tag = f" uuid={m.group(1).decode()}"
        self._record(f"{code}{tag}")
        self._respond(code, out)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("--listen-port", type=int, required=True)
    p.add_argument("--upstream", required=True)
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--inject", type=int, default=503, choices=[503, 404])
    p.add_argument("--log", required=True)
    args = p.parse_args()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", args.listen_port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
