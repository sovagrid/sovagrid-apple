#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Exercise native service status and one confirmed mutation against a local Hub fixture."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

from run_key_import import HERE, capture, run_logged, simulator_type


SERVER = "11111111-1111-4111-8111-111111111111"
STATUS_JOB = "22222222-2222-4222-8222-222222222222"
RESTART_JOB = "33333333-3333-4333-8333-333333333333"
TOKEN = "fixture-service-session"
USER = {"id": "fixture-service-user", "username": "fixture-service-admin",
        "role": "admin", "enabled": True}


def handler(events):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            if self.headers.get("Authorization") == "Bearer " + TOKEN:
                return True
            self.reply(401, {"error": "Missing fixture session"})
            return False

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            data = json.loads(body)
            if self.path == "/api/v1/session":
                events.append(("POST", "session"))
                if data == {"username": USER["username"], "password": "fixture-password"}:
                    return self.reply(200, {"token": TOKEN, "user": USER})
                return self.reply(401, {"error": "Invalid fixture login"})
            if not self.authorized():
                return
            if self.path != f"/api/v1/servers/{SERVER}/services/actions":
                return self.reply(404, {"error": "Unexpected route"})
            try:
                key = self.headers["Idempotency-Key"]
                assert str(uuid.UUID(key)) == key
                assert set(data) == {"action", "unit"} and data["unit"] == "nginx.service"
                assert data["action"] in ("status", "restart")
            except (AssertionError, KeyError, ValueError):
                return self.reply(400, {"error": "Invalid structured service request"})
            events.append(("POST", data["action"]))
            if data["action"] == "restart" and ("POST", "status") not in events:
                return self.reply(503, {"error": "Status required"})
            job = STATUS_JOB if data["action"] == "status" else RESTART_JOB
            return self.reply(201, {"job": {"id": job, "state": "queued"}})

        def do_GET(self):
            if not self.authorized():
                return
            events.append(("GET", self.path))
            if self.path == "/api/v1/session":
                return self.reply(200, {"user": USER, "expires_at": 2_000_000_000})
            if self.path == "/api/v1/session/access":
                return self.reply(200, {"access": {"mode": "all", "revision": 0,
                                                       "unrestricted_admin": True}})
            if self.path == "/api/v1/servers":
                return self.reply(200, {"servers": [{"id": SERVER, "name": "Fixture server",
                    "online": True, "remote_commands_enabled": True, "access_role": "admin",
                    "last_seen": int(time.time()), "latest": None}]})
            if self.path in ("/api/v1/incidents?state=firing", "/api/v1/incidents?state=resolved"):
                return self.reply(200, {"incidents": []})
            if self.path == f"/api/v1/servers/{SERVER}/checks":
                return self.reply(200, {"server_id": SERVER, "revision": 0,
                                        "worker_seen_at": int(time.time()), "checks": []})
            if self.path == f"/api/v1/jobs/{STATUS_JOB}":
                output = json.dumps({"action": "status", "unit": "nginx.service", "result": "ok",
                    "load_state": "loaded", "active_state": "active", "sub_state": "running"})
                return self.reply(200, {"job": {"id": STATUS_JOB, "state": "succeeded",
                                                 "exit_code": 0, "output": output}})
            if self.path == f"/api/v1/jobs/{RESTART_JOB}":
                output = json.dumps({"action": "restart", "unit": "nginx.service", "result": "ok",
                    "load_state": "loaded", "active_state": "active", "sub_state": "running"})
                return self.reply(200, {"job": {"id": RESTART_JOB, "state": "succeeded",
                                                 "exit_code": 0, "output": output}})
            if self.path == f"/api/v1/servers/{SERVER}/services/control?unit=nginx.service":
                return self.reply(200, {"control": {"source_status": "ok", "unit": "nginx.service",
                    "observed_at": int(time.time()), "load_state": "loaded",
                    "active_state": "active", "sub_state": "running"}})
            return self.reply(404, {"error": "Unexpected route"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="sovagrid-hub-service-"))
    events = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(events))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    simulator = None
    try:
        runtime, device_type = simulator_type()
        simulator = capture("xcrun", "simctl", "create",
                            f"SovaGrid service {uuid.uuid4().hex[:8]}", device_type, runtime)
        capture("xcrun", "simctl", "boot", simulator)
        run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
        capture("xcrun", "simctl", "install", simulator, str(args.app.resolve()))
        project = output / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (output / "SmokeTests").mkdir()
        source = (HERE / "HubServiceUITests.swift").read_text().replace(
            '"__FIXTURE_ADDRESS__"', json.dumps(f"http://127.0.0.1:{server.server_port}"))
        (output / "SmokeTests/SmokeTests.swift").write_text(source)
        run_logged(["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(output / "test-build"),
            "-resultBundlePath", str(output / "services.xcresult"),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-only-testing:SmokeTests/HubServiceUITests",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"], output / "services.log")
        assert events.count(("POST", "status")) == 1, events
        assert events.count(("POST", "restart")) == 1, events
        assert ("GET", f"/api/v1/jobs/{STATUS_JOB}") in events
        assert ("GET", f"/api/v1/jobs/{RESTART_JOB}") in events
        assert events.count(("GET", f"/api/v1/servers/{SERVER}/services/control?unit=nginx.service")) >= 2
        print("PASS native admin status, confirmation and one restart job", flush=True)
    finally:
        (output / "events.json").write_text(json.dumps(events, indent=2) + "\n")
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        if simulator:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.sovagrid.app"], capture_output=True)
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True, check=True)
        print(f"Diagnostic logs: {output}", flush=True)


if __name__ == "__main__":
    main()
