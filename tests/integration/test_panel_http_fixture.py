#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Keep the iPhone route fixture aligned with the Hub discovery contract."""

import functools
import http.client
import http.server
import json
from pathlib import Path
import tempfile
import threading
import unittest

from panel_http_fixture import PanelHandler


class PanelHTTPFixtureTest(unittest.TestCase):
    def test_legacy_pending_and_custom_panel(self):
        with tempfile.TemporaryDirectory() as temporary:
            panel = Path(temporary) / "ops/panel"
            panel.mkdir(parents=True)
            (panel / "index.html").write_text("<html>SovaGrid fixture</html>")
            (panel / "manifest.webmanifest").write_text('{"name":"SovaGrid fixture"}')
            PanelHandler.custom_path = False
            PanelHandler.pending_reads = 0
            handler = functools.partial(PanelHandler, directory=temporary)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def get(path):
                    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                    connection.request("GET", path)
                    response = connection.getresponse()
                    result = response.status, response.getheader("Content-Type"), response.read()
                    connection.close()
                    return result

                self.assertEqual(get("/api/v1/panel-location")[0], 404)
                self.assertEqual(get("/_fixture/custom-path")[0], 200)
                self.assertEqual(get("/sovagrid/monitoring/")[0], 503)
                self.assertEqual(get("/api/v1/panel-location")[0], 503)
                self.assertEqual(get("/api/v1/panel-location")[0], 503)
                status, mime, payload = get("/api/v1/panel-location")
                self.assertEqual((status, mime), (200, "application/json"))
                self.assertEqual(json.loads(payload), {"panel_path": "/ops/panel/"})
                self.assertEqual(get("/ops/panel/")[0], 200)
                status, mime, payload = get("/ops/panel/manifest.webmanifest")
                self.assertEqual(status, 200)
                self.assertTrue(mime.startswith("application/manifest+json"))
                self.assertEqual(json.loads(payload)["name"], "SovaGrid fixture")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
