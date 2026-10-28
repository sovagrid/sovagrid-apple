#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Exercise Hub identity and actual Keychain logout in a clean iPhone Simulator.

Only a local HTTP fixture with synthetic credentials is used. No remote or real
account is contacted. Every created Simulator and fixture listener is removed.
"""

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


class Fixture:
    def __init__(self):
        self.mode = "valid"
        self.calls = []
        self.lock = threading.Lock()

    def record(self, method, path):
        with self.lock:
            self.calls.append((self.mode, method, path))

    def user(self):
        value = {"id": "fixture-user", "username": "fixture-phone", "role": "viewer", "enabled": True}
        with self.lock:
            mode = self.mode
        if mode == "changed":
            value["id"] = "different-fixture-user"
        elif mode == "unknown":
            value["role"] = "unknown-role"
        elif mode == "disabled":
            value["enabled"] = False
        return value


def handler(fixture):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_json(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            fixture.record("POST", self.path)
            content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.path != "/api/v1/session" or json.loads(content) != {
                    "username": "fixture-phone", "password": "local-fixture-password"}:
                self.send_json(401, {"error": "Invalid fixture credentials"})
                return
            self.send_json(200, {"token": "local-fixture-session", "user": fixture.user()})

        def do_GET(self):
            fixture.record("GET", self.path)
            if self.headers.get("Authorization") != "Bearer local-fixture-session":
                self.send_json(401, {"error": "Missing fixture authentication"})
            elif self.path == "/api/v1/session":
                self.send_json(200, {"user": fixture.user(), "expires_at": 2000000000})
            elif self.path == "/api/v1/servers":
                self.send_json(200, {"servers": [{"id": "fixture-server", "name": "Fixture Hub server",
                    "online": True, "latest": {"cpu_percent": 8.0, "memory_percent": 22.0, "disk_percent": 12.0}}]})
            else:
                self.send_json(404, {"error": "Fixture route unavailable"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Ad hoc signed iOS Simulator app")
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="sovagrid-hub-identity-"))
    fixture = Fixture()
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(fixture))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    simulator = None
    try:
        runtime, device_type = simulator_type()
        simulator = capture("xcrun", "simctl", "create", f"SovaGrid Hub identity {uuid.uuid4().hex[:8]}", device_type, runtime)
        capture("xcrun", "simctl", "boot", simulator)
        run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
        capture("xcrun", "simctl", "install", simulator, str(args.app.resolve()))
        project = output / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (output / "SmokeTests").mkdir()
        source = (HERE / "HubIdentityUITests.swift").read_text().replace('"__FIXTURE_ADDRESS__"',
            json.dumps(f"http://127.0.0.1:{server.server_port}"))
        (output / "SmokeTests/SmokeTests.swift").write_text(source)

        def test_case(mode, method):
            run_logged(["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
                "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
                "-derivedDataPath", str(output / "test-build"), "-resultBundlePath", str(output / f"{mode}-{method}.xcresult"),
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                f"-only-testing:SmokeTests/HubIdentityUITests/{method}", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"],
                output / f"{mode}-{method}.log")

        for mode in ("changed", "unknown", "disabled"):
            fixture.mode = "valid"
            test_case(mode, "test01LoginShowsViewer")
            fixture.mode = mode
            start = len(fixture.calls)
            test_case(mode, "test02InvalidIdentityRequiresLogin")
            assert any(call == (mode, "GET", "/api/v1/session") for call in fixture.calls[start:])
            assert not any(call == (mode, "GET", "/api/v1/servers") for call in fixture.calls[start:])
            request_count = len(fixture.calls)
            test_case(mode, "test03TokenStaysRemovedAfterRestart")
            assert len(fixture.calls) == request_count, "Restart reused a token that should have been removed from Keychain"
            print(f"PASS {mode} Hub identity clears Keychain session, hides cached metrics, and requires login after restart", flush=True)
        (output / "result.json").write_text(json.dumps({"passed": True,
            "cases": ["changed", "unknown", "disabled"], "no_real_accounts": True}, indent=2) + "\n")
    finally:
        (output / "fixture-calls.json").write_text(json.dumps(fixture.calls, indent=2) + "\n")
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
