#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Read-only iPhone Hub smoke test. Credentials stay in memory and a one-use loopback reply."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import urllib.request
import uuid

from run_key_import import HERE, capture, run_logged, simulator_type


def hub_request(origin, path, method="GET", token=None, body=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(origin + path, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def choose_inventory(origin, username, password):
    session = hub_request(origin, "/api/v1/session", "POST", body=json.dumps({
        "username": username, "password": password.decode("utf-8")
    }).encode("utf-8"))
    token = session.get("token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("Hub did not create an admin session")
    try:
        reply = hub_request(origin, "/api/v1/servers", token=token)
        servers = reply.get("servers", [])
        if not isinstance(servers, list):
            raise RuntimeError("Hub did not return a server list")
        for server in servers:
            if not server.get("online") or not server.get("remote_commands_enabled"):
                continue
            latest = server.get("latest") or {}
            snapshot = (latest.get("details") or {}).get("containers") or {}
            engines = snapshot.get("engines") or []
            docker = next((item for item in engines if item.get("engine") == "docker"), None)
            if not docker or docker.get("source_status") != "ok" or docker.get("truncated"):
                continue
            protected = next((item.get("name") for item in docker.get("containers", [])
                              if str(item.get("name", "")).startswith("sovagrid")), None)
            if protected and re.fullmatch(r"[0-9a-fA-F-]{36}", server.get("id", "")):
                return server["id"], server["name"], protected, len(servers), len(docker["containers"])
        raise RuntimeError("No online server has a complete Docker inventory with a protected item")
    finally:
        try:
            hub_request(origin, "/api/v1/session", "DELETE", token=token)
        except Exception:
            # The short-lived preflight session expires even if deletion fails.
            pass


def password_handler(secret, nonce):
    lock = threading.Lock()
    served = False

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            nonlocal served
            with lock:
                if self.path != "/one-use/" + nonce or served:
                    self.send_error(404)
                    return
                served = True
                body = bytes(secret)
                secret[:] = b"\0" * len(secret)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--hub", required=True, help="Trusted HTTPS origin, for example https://192.0.2.1")
    parser.add_argument("--ssh-host", required=True)
    parser.add_argument("--username", default="admin")
    parser.add_argument("--password-file", default="/etc/sovagrid/admin-password")
    args = parser.parse_args()
    os.umask(0o077)
    origin = args.hub.rstrip("/")
    if not origin.startswith("https://") or "/" in origin[len("https://"):] or not args.app.is_dir():
        parser.error("--hub must be a trusted HTTPS origin and --app a Simulator .app directory")
    remote_command = "cat -- " + shlex.quote(args.password_file)
    read = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                           "root@" + args.ssh_host, remote_command],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=15)
    secret = bytearray(read.stdout.rstrip(b"\r\n"))
    if not 8 <= len(secret) <= 256 or any(byte < 33 or byte > 126 for byte in secret):
        raise RuntimeError("Password file did not contain a bounded printable credential")
    simulator = None
    password_server = None
    thread = None
    try:
        server_id, server_name, protected_name, server_count, container_count = choose_inventory(
            origin, args.username, secret)
        print(f"Preflight: {server_count} servers; selected Docker inventory has {container_count} items.", flush=True)
        nonce = uuid.uuid4().hex + uuid.uuid4().hex
        password_server = ThreadingHTTPServer(("127.0.0.1", 0), password_handler(secret, nonce))
        thread = threading.Thread(target=password_server.serve_forever, daemon=True)
        thread.start()
        password_url = f"http://127.0.0.1:{password_server.server_port}/one-use/{nonce}"
        with tempfile.TemporaryDirectory(prefix="sovagrid-live-hub-readonly-") as temporary:
            output = Path(temporary)
            runtime, device_type = simulator_type()
            simulator = capture("xcrun", "simctl", "create",
                                f"SovaGrid live Hub read-only {uuid.uuid4().hex[:8]}", device_type, runtime)
            capture("xcrun", "simctl", "boot", simulator)
            run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
            capture("xcrun", "simctl", "install", simulator, str(args.app.resolve()))
            project = output / "Smoke.xcodeproj"
            shutil.copytree(HERE / "Smoke.xcodeproj", project)
            (output / "SmokeTests").mkdir()
            source = (HERE / "HubLiveReadOnlyUITests.swift").read_text()
            for key, value in {"__HUB_ADDRESS__": origin, "__HUB_USERNAME__": args.username,
                               "__SERVER_ID__": server_id, "__SERVER_NAME__": server_name,
                               "__PROTECTED_NAME__": protected_name,
                               "__PASSWORD_URL__": password_url}.items():
                source = source.replace('"' + key + '"', json.dumps(value))
            (output / "SmokeTests/SmokeTests.swift").write_text(source)
            command = ["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
                       "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
                       "-derivedDataPath", str(output / "test-build"),
                       "-resultBundlePath", str(output / "readonly.xcresult"),
                       "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                       "-only-testing:SmokeTests/HubLiveReadOnlyUITests",
                       "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=240, check=False)
            sanitized = result.stdout.replace(bytes(read.stdout.rstrip(b"\r\n")), b"[redacted]")
            if result.returncode:
                lines = sanitized.decode("utf-8", "replace").splitlines()
                for line in lines:
                    if "error:" in line or "Test Case" in line or "SOVAGRID_LIVE_HUB" in line:
                        print(line[-500:], flush=True)
                raise RuntimeError("iPhone Simulator read-only Hub UI test failed")
            if b"SOVAGRID_LIVE_HUB_READ_ONLY_PASSED" not in sanitized:
                raise RuntimeError("iPhone Simulator did not report the read-only success marker")
            print("PASS iPhone HTTPS admin login, server list, protected Docker UI and logout.", flush=True)
    finally:
        secret[:] = b"\0" * len(secret)
        if password_server:
            password_server.shutdown()
            password_server.server_close()
        if thread:
            thread.join(timeout=5)
        if simulator:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.sovagrid.app"], capture_output=True)
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True, check=True)


if __name__ == "__main__":
    main()
