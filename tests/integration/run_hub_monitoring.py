#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Verify viewer-safe native Hub monitoring with a disposable local HTTP fixture."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import uuid

from run_key_import import HERE, capture, run_logged, simulator_type


SERVER = "11111111-1111-4111-8111-111111111111"
CHECK = "22222222-2222-4222-8222-222222222222"
USER = {"id": "fixture-viewer-id", "username": "fixture-viewer",
        "role": "viewer", "enabled": True}


def handler(requests):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_json(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            requests.append(("POST", self.path))
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.path == "/api/v1/session" and json.loads(body) == {
                    "username": "fixture-viewer", "password": "fixture-password"}:
                self.send_json(200, {"token": "fixture-viewer-session", "user": USER})
            else:
                self.send_json(401, {"error": "Invalid fixture login"})

        def do_GET(self):
            requests.append(("GET", self.path))
            if self.headers.get("Authorization") != "Bearer fixture-viewer-session":
                self.send_json(401, {"error": "Missing fixture session"})
            elif self.path == "/api/v1/session":
                self.send_json(200, {"user": USER, "expires_at": 2000000000})
            elif self.path == "/api/v1/servers":
                self.send_json(200, {"servers": [{
                    "id": SERVER, "name": "Demo server", "created_at": 1700000000,
                    "last_seen": 1700000002, "online": True,
                    "remote_commands_enabled": False, "maintenance": None,
                    "latest": {"collected_at": 1700000000, "cpu_percent": 12,
                        "memory_percent": 28, "disk_percent": 43,
                        "network_rx_bytes": 100, "network_tx_bytes": 200,
                        "load1": 0.4, "uptime_seconds": 3600,
                        "details": {"clock": {"system_utc_epoch": 1699999835,
                            "timezone": "Europe/Moscow", "ntp_synchronized": False,
                            "rtc_local_time": False, "rtc_utc_epoch": 1700000000,
                            "rtc_offset_seconds": 165}}}}]})
            elif self.path == f"/api/v1/servers/{SERVER}/checks":
                self.send_json(200, {"server_id": SERVER, "revision": 2,
                    "worker_seen_at": 1700000004, "checks": [{
                        "id": CHECK, "name": "Панель HTTPS", "kind": "http",
                        "enabled": True, "interval_seconds": 60, "timeout_seconds": 5,
                        "state": "up", "url": "https://secret.example/private-target",
                        "latest": {"observed_at": 1700000000, "received_at": 1700000003,
                            "status": "up", "latency_ms": 42, "http_status": 200,
                            "tls_expires_at": 1800000000, "error_code": None}}, {
                        "id": "33333333-3333-4333-8333-333333333333", "name": "SSH TCP",
                        "kind": "tcp", "enabled": True, "interval_seconds": 120,
                        "timeout_seconds": 3, "state": "down", "latest": {
                            "observed_at": 1700000001, "received_at": 1700000004,
                            "status": "down", "latency_ms": 3000, "http_status": None,
                            "tls_expires_at": None, "error_code": "timeout"}}]})
            elif self.path == "/api/v1/incidents?state=firing":
                self.send_json(200, {"incidents": [{
                    "id": "firing-incident", "server_id": SERVER, "server_name": "Demo server",
                    "kind": f"check:{CHECK}", "subject": "Панель HTTPS", "state": "firing",
                    "opened_at": 1700000000, "updated_at": 1700000050,
                    "resolved_at": None, "acknowledged_at": None,
                    "current_value": None, "threshold": None, "alerted_at": 1700000050}]})
            elif self.path == "/api/v1/incidents?state=resolved":
                self.send_json(200, {"incidents": [{
                    "id": "resolved-incident", "server_id": SERVER, "server_name": "Demo server",
                    "kind": "high_cpu", "subject": None, "state": "resolved",
                    "opened_at": 1700000000, "updated_at": 1700000600,
                    "resolved_at": 1700000600, "acknowledged_at": None,
                    "current_value": 25, "threshold": 90, "alerted_at": 1700000000}]})
            else:
                self.send_json(404, {"error": "Fixture route unavailable"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Ad hoc signed iOS Simulator app")
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="sovagrid-hub-monitoring-"))
    requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(requests))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    simulator = None
    try:
        runtime, device_type = simulator_type()
        simulator = capture("xcrun", "simctl", "create",
                            f"SovaGrid Hub monitoring {uuid.uuid4().hex[:8]}", device_type, runtime)
        capture("xcrun", "simctl", "boot", simulator)
        run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
        capture("xcrun", "simctl", "install", simulator, str(args.app.resolve()))
        project = output / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (output / "SmokeTests").mkdir()
        source = (HERE / "HubMonitoringUITests.swift").read_text().replace(
            '"__FIXTURE_ADDRESS__"', json.dumps(f"http://127.0.0.1:{server.server_port}"))
        (output / "SmokeTests/SmokeTests.swift").write_text(source)
        run_logged(["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(output / "test-build"),
            "-resultBundlePath", str(output / "monitoring.xcresult"),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-only-testing:SmokeTests/HubMonitoringUITests",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"], output / "monitoring.log")
        expected = {("GET", "/api/v1/session"), ("GET", "/api/v1/servers"),
                    ("GET", f"/api/v1/servers/{SERVER}/checks"),
                    ("GET", "/api/v1/incidents?state=firing"),
                    ("GET", "/api/v1/incidents?state=resolved")}
        assert expected.issubset(set(requests)), "Monitoring API requests missing"
        assert all(requests.count(request) == 1 for request in expected), "Monitoring refreshed twice after login"
        assert not any("/checks/config" in path for _, path in requests), "Viewer requested target configuration"
        print("PASS viewer sees sanitized checks, firing/resolved incidents and RTC diagnostics", flush=True)
    finally:
        (output / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
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
