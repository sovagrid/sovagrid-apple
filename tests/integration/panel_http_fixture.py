#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Disposable Hub Web fixture: legacy 404, then transient 503 and custom path."""

import http.server
import json
import sys
from pathlib import Path


class PanelHandler(http.server.SimpleHTTPRequestHandler):
    custom_path = False
    pending_reads = 0

    def do_GET(self):
        if self.path == "/_fixture/custom-path":
            type(self).custom_path = True
            type(self).pending_reads = 2
            self._reply(200, b"ok", "text/plain")
            return
        if self.path == "/api/v1/panel-location" and self.custom_path:
            if self.pending_reads:
                type(self).pending_reads -= 1
                self._reply(503, b"pending", "text/plain")
            else:
                payload = json.dumps({"panel_path": "/ops/panel/"}).encode()
                self._reply(200, payload, "application/json")
            return
        if self.custom_path and self.path.startswith("/sovagrid/monitoring/"):
            self._reply(503, b"old route unavailable", "text/plain")
            return
        super().do_GET()

    def _reply(self, status, payload, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    folder = Path(sys.argv[1]).resolve()
    handler = lambda *args, **kwargs: PanelHandler(*args, directory=str(folder), **kwargs)
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), handler).serve_forever()
