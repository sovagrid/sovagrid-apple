#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Import an ephemeral key through Files and run harmless commands on a test server.

Requires explicit --server and existing non-interactive root SSH authorization.
Creates one uniquely named unprivileged account with key-only access and a
20-minute cleanup timer. Removes only that marked account, the generated key,
and the newly created Simulator. Never copies an administrator key into iOS.
Diagnostic logs remain in the printed temporary directory with mode 0700.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import uuid


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def capture(*command, input=None):
    result = subprocess.run(command, input=input, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def run_logged(command, path):
    with path.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=600)
    path.chmod(0o600)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}); see {path}")


def remote(server, script):
    return capture("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                   "--", f"root@{server}", "/bin/sh -s", input=script)


def simulator_type():
    devices = json.loads(capture("xcrun", "simctl", "list", "-j", "devices", "available"))["devices"]
    for runtime, entries in devices.items():
        for device in entries:
            if "SimRuntime.iOS-" in runtime and device["name"] == "iPhone 18 Pro":
                return runtime, device["deviceTypeIdentifier"]
    raise RuntimeError("No available iPhone 18 Pro Simulator runtime")


def local_storage(simulator):
    # System Files exposes its local provider as a registered app group. This
    # seeds a fixture document only; app credentials are not injected or patched.
    for line in capture("xcrun", "simctl", "get_app_container", simulator,
                        "com.apple.DocumentsApp", "groups").splitlines():
        name, path = line.split("\t", 1)
        if name == "group.com.apple.FileProvider.LocalStorage":
            return Path(path) / "File Provider Storage"
    raise RuntimeError("System Files local provider group unavailable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, help="Authorized Ubuntu test host; root SSH must already work")
    parser.add_argument("--app", type=Path, help="Existing ad hoc signed iOS Simulator .app; otherwise build it")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", args.server):
        parser.error("server must be an IP address or DNS hostname")

    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="sovagrid-key-import-"))
    secret_folder = output / "secrets"
    secret_folder.mkdir(mode=0o700)
    suffix = uuid.uuid4().hex[:10]
    account = f"sg-ios-{suffix}"
    home = f"/home/{account}"
    marker = f"SovaGrid temporary UI test {suffix}"
    timer = f"sovagrid-ios-cleanup-{suffix}"
    simulator = None
    provision_attempted = False
    cleanup = f"""set -eu
account={shlex.quote(account)}
record=$(getent passwd "$account" || true)
[ -n "$record" ] || exit 0
actual_marker=$(printf '%s' "$record" | cut -d: -f5)
actual_home=$(printf '%s' "$record" | cut -d: -f6)
[ "$actual_marker" = {shlex.quote(marker)} ] || exit 23
[ "$actual_home" = {shlex.quote(home)} ] || exit 24
pkill -TERM -u "$account" 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    pgrep -u "$account" >/dev/null || break
    sleep 1
done
if pgrep -u "$account" >/dev/null; then
    pkill -KILL -u "$account" 2>/dev/null || true
    sleep 1
fi
userdel --remove "$account"
"""
    try:
        key = secret_folder / "server_ed25519"
        capture("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                "-C", "sovagrid-ios-import-fixture", "-f", str(key))
        public = key.with_suffix(".pub").read_text().strip()
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+ sovagrid-ios-import-fixture", public):
            raise RuntimeError("Unexpected generated public-key format")
        fingerprints = remote(args.server,
            "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256\n")
        match = re.search(r"SHA256:[A-Za-z0-9+/]+", fingerprints)
        if not match:
            raise RuntimeError("Server Ed25519 public host fingerprint unavailable")
        fingerprint = match.group(0)
        provision_attempted = True
        remote(args.server, f"""set -eu
umask 077
! getent passwd {shlex.quote(account)} >/dev/null
[ ! -e {shlex.quote(home)} ]
useradd --create-home --user-group --home-dir {shlex.quote(home)} --shell /bin/sh --comment {shlex.quote(marker)} --password '!' {shlex.quote(account)}
install -d -m 0700 -o {shlex.quote(account)} -g {shlex.quote(account)} {shlex.quote(home + '/.ssh')}
printf '%s\\n' {shlex.quote('restrict,pty ' + public)} > {shlex.quote(home + '/.ssh/authorized_keys')}
chown {shlex.quote(account + ':' + account)} {shlex.quote(home + '/.ssh/authorized_keys')}
chmod 0600 {shlex.quote(home + '/.ssh/authorized_keys')}
systemd-run --quiet --unit={shlex.quote(timer)} --on-active=20m /bin/sh -c {shlex.quote(cleanup)}
""")
        print("PASS disposable unprivileged server account provisioned", flush=True)

        runtime, device_type = simulator_type()
        simulator = capture("xcrun", "simctl", "create", f"SovaGrid key import {suffix}", device_type, runtime)
        capture("xcrun", "simctl", "boot", simulator)
        run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
        app = args.app.resolve() if args.app else output / "app-build/Build/Products/Debug-iphonesimulator/SovaGrid.app"
        if not args.app:
            run_logged(["xcodebuild", "build", "-project", str(ROOT / "SovaGrid.xcodeproj"),
                "-scheme", "SovaGrid", "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
                "-derivedDataPath", str(output / "app-build"), "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"],
                output / "app-build.log")
        capture("xcrun", "simctl", "install", simulator, str(app))
        fixture_name = f"SovaGridKeyFixture-{suffix}"
        provider = local_storage(simulator) / fixture_name
        provider.mkdir(mode=0o700, parents=True, exist_ok=False)
        shutil.copy2(key, provider / key.name)

        project = output / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (output / "SmokeTests").mkdir()
        source = (HERE / "KeyImportTests.swift").read_text()
        for name, value in {"HOST": args.server, "USERNAME": account,
                            "FOLDER": fixture_name, "FINGERPRINT": fingerprint}.items():
            source = source.replace(json.dumps(f"__FIXTURE_{name}__"), json.dumps(value))
        (output / "SmokeTests/SmokeTests.swift").write_text(source)
        run_logged(["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(output / "test-build"), "-resultBundlePath", str(output / "key-import.xcresult"),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-only-testing:SmokeTests/KeyImportTests/testImportKeyAndConnect",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"], output / "key-import.log")
        result = remote(args.server, f"cat -- {shlex.quote(home + '/.sovagrid-ui-result')}\n")
        if result != f"Linux\n{account}":
            raise RuntimeError("UI terminal command result did not match disposable Linux account")
        print("PASS actual Files import, checked host fingerprint, SSH login, uname and id from UI", flush=True)
        (output / "result.json").write_text(json.dumps({"passed": True, "command_os": "Linux",
            "host_fingerprint_verified": True, "credentials_injected_into_app_storage": False}, indent=2) + "\n")
    finally:
        cleanup_errors = []
        if simulator:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.sovagrid.app"], capture_output=True)
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            result = subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True)
            if result.returncode:
                cleanup_errors.append(f"Simulator deletion failed: {simulator}")
        shutil.rmtree(secret_folder, ignore_errors=True)
        if provision_attempted:
            try:
                remote(args.server, cleanup)
                remote(args.server, f"systemctl stop {shlex.quote(timer + '.timer')} 2>/dev/null || true\n")
                if remote(args.server, f"getent passwd {shlex.quote(account)} || true\n"):
                    raise RuntimeError("Disposable account cleanup was not confirmed")
                print("PASS disposable server account and Simulator removed", flush=True)
            except Exception as error:
                cleanup_errors.append(str(error))
        print(f"Diagnostic logs: {output}", flush=True)
        if cleanup_errors:
            raise RuntimeError("; ".join(cleanup_errors))


if __name__ == "__main__":
    main()
