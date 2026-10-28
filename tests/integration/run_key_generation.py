#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Generate and copy public SSH keys in a clean iPhone Simulator, without SSH login."""

import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

from run_key_import import HERE, capture, run_logged, simulator_type


def validate_public_key(value):
    algorithm, encoded = value.split(" ")
    assert algorithm == "ssh-ed25519"
    blob = base64.b64decode(encoded, validate=True)
    assert blob[:4] == (11).to_bytes(4, "big")
    assert blob[4:15] == b"ssh-ed25519"
    assert blob[15:19] == (32).to_bytes(4, "big")
    assert len(blob) == 51


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Ad hoc signed iOS Simulator app")
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="sovagrid-key-generation-"))
    simulator = None
    try:
        runtime, device_type = simulator_type()
        simulator = capture("xcrun", "simctl", "create", f"SovaGrid key generation {uuid.uuid4().hex[:8]}", device_type, runtime)
        capture("xcrun", "simctl", "boot", simulator)
        run_logged(["xcrun", "simctl", "bootstatus", simulator, "-b"], output / "boot.log")
        capture("xcrun", "simctl", "install", simulator, str(args.app.resolve()))
        project = output / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (output / "SmokeTests").mkdir()
        shutil.copy2(HERE / "KeyGenerationTests.swift", output / "SmokeTests/SmokeTests.swift")
        run_logged(["xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(output / "test-build"), "-resultBundlePath", str(output / "key-generation.xcresult"),
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-only-testing:SmokeTests/KeyGenerationTests", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"],
            output / "key-generation.log")
        log = (output / "key-generation.log").read_text(errors="replace")
        public = {}
        for kind in ("TARGET", "JUMP", "PROFILE_TARGET", "PROFILE_JUMP", "AFTER_DELETE_TARGET", "AFTER_DELETE_JUMP"):
            match = re.search(rf"SOVAGRID_GENERATED_{kind}_PUBLIC_KEY=(ssh-ed25519 [A-Za-z0-9+/=]+)", log)
            assert match, f"Missing public key evidence: {kind}"
            public[kind] = match.group(1)
            validate_public_key(public[kind])
        assert public["TARGET"] != public["JUMP"]
        assert public["PROFILE_TARGET"] == public["TARGET"]
        assert public["PROFILE_JUMP"] == public["JUMP"]
        assert public["AFTER_DELETE_TARGET"] == public["TARGET"]
        assert public["AFTER_DELETE_JUMP"] == public["JUMP"]
        assert capture("xcrun", "simctl", "pbpaste", simulator) == public["JUMP"], "Clipboard must contain only the selected public key"
        for kind in ("TARGET", "JUMP"):
            path = output / (kind.lower() + ".pub")
            path.write_text(public[kind] + "\n")
            capture("/usr/bin/ssh-keygen", "-lf", str(path), "-E", "sha256")
        container = Path(capture("xcrun", "simctl", "get_app_container", simulator, "com.sovagrid.app", "data"))
        # CFPreferences writes to disk asynchronously. Verify the durable file
        # after its update, rather than racing the daemon immediately after UI.
        deadline = time.monotonic() + 10
        while True:
            with (container / "Library/Preferences/com.sovagrid.app.plist").open("rb") as source:
                preferences = plistlib.load(source)
            records = json.loads(preferences["sovagrid.ssh.key-library.v1"])
            if len(records) == 1 or time.monotonic() >= deadline:
                break
            time.sleep(0.2)
        assert len(records) == 1 and records[0]["name"] == "Fixture target key"
        assert all(set(item) == {"id", "name", "createdAt"} for item in records), "Only public metadata may persist in preferences"
        profiles = json.loads(preferences["sovagrid.ssh.servers.v1"])
        assert len(profiles) == 1 and profiles[0]["auth"] == "Ключ Ed25519"
        assert profiles[0]["jump"]["auth"] == "Ключ Ed25519"
        text = json.dumps({"keys": records, "profiles": profiles})
        assert "PRIVATE KEY" not in text and '"seed"' not in text and '"password"' not in text
        print("PASS two distinct generated key pairs, public-only clipboard, Keychain persistence, independent target/jump choices and safe library deletion", flush=True)
        (output / "result.json").write_text(json.dumps({"passed": True,
            "generated_pairs": 2, "public_keys_validated_by_openssh": True,
            "clipboard_contains_public_key_only": True, "metadata_contains_no_private_key": True,
            "library_deletion_preserves_saved_profile_keys": True}, indent=2) + "\n")
    finally:
        if simulator:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, "com.sovagrid.app"], capture_output=True)
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", simulator], capture_output=True, check=True)
        print(f"Diagnostic logs: {output}", flush=True)


if __name__ == "__main__":
    main()
