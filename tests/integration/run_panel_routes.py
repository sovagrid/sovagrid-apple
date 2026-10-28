#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Exercise both Panel routes against disposable local SSH and HTTP fixtures.

Requires macOS, Xcode with an iPhone Simulator runtime, and system sshd/ssh-keygen.
The app and test runner use a newly created Simulator; no real server is contacted.
"""

import http.server
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SSH_DAEMON = "/usr/sbin/sshd"
SSH_KEYGEN = "/usr/bin/ssh-keygen"
ENTRY_PORT = 22221
TARGET_PORT = 22222
PANEL_PORT = 8766
BLACKHOLE_PORT = 22223


def run(*args, log=None):
    if log is None:
        subprocess.run(args, check=True)
        return ""
    with log.open("w") as output:
        result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}); see {log}")
    return log.read_text(errors="replace")


def simulator_type():
    result = subprocess.check_output(["xcrun", "simctl", "list", "-j", "devices", "available"])
    candidates = []
    for runtime, devices in json.loads(result)["devices"].items():
        if "SimRuntime.iOS-" not in runtime:
            continue
        for device in devices:
            if device["name"].startswith("iPhone") and device["isAvailable"]:
                candidates.append((runtime, device["deviceTypeIdentifier"], device["name"]))
    for runtime, device_type, name in candidates:
        if name == "iPhone 18 Pro":
            return runtime, device_type
    if candidates:
        return candidates[0][:2]
    raise RuntimeError("No available iPhone Simulator runtime")


def make_sshd_config(folder, name, port, user, permit_open, force_command=True):
    config = folder / f"{name}.conf"
    command = folder / f"{name}-command.sh"
    command.write_text(f'#!/bin/sh\nprintf "%s\\n" "{name.upper()}_FIXTURE_PASSWORD_123456789"\n')
    command.chmod(0o700)
    lines = [
        f"Port {port}",
        "ListenAddress 127.0.0.1",
        f"HostKey {folder / (name + '-host')}",
        f"AuthorizedKeysFile {folder / (name + '-authorized')}",
        "PasswordAuthentication no",
        "PubkeyAuthentication yes",
        "KbdInteractiveAuthentication no",
        "UsePAM no",
        "StrictModes no",
        f"AllowUsers {user}",
        "AllowTcpForwarding yes",
        f"PermitOpen {permit_open}",
        "PermitTTY yes",
        f"PidFile {folder / (name + '.pid')}",
        "LogLevel ERROR",
    ]
    if force_command:
        lines.append(f"ForceCommand /bin/sh {command}")
    else:
        lines.append("Subsystem sftp /usr/libexec/sftp-server")
    config.write_text("\n".join(lines + [""]))
    return config


def start_sshd(config, log):
    output = log.open("w")
    process = subprocess.Popen([SSH_DAEMON, "-D", "-e", "-f", str(config)],
                               stdout=output, stderr=subprocess.STDOUT)
    time.sleep(0.5)
    if process.poll() is not None:
        output.close()
        raise RuntimeError(f"sshd exited early; see {log}")
    return process, output


def stop_process(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def test_case(project, folder, simulator, method):
    log = folder / f"{method}.log"
    result = folder / f"{method}.xcresult"
    output = run("xcodebuild", "test", "-project", str(project), "-scheme", "SmokeTests",
                 "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator}",
                 "-derivedDataPath", str(folder / "test-build"), "-resultBundlePath", str(result),
                 "-parallel-testing-enabled", "NO",
                 f"-only-testing:SmokeTests/SmokeTests/{method}",
                 "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", log=log)
    if "** TEST SUCCEEDED **" not in output:
        raise RuntimeError(f"Test did not report success; see {log}")
    print(f"PASS {method}", flush=True)
    return output


def verify_sftp_download(folder, simulator):
    container = Path(subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", simulator, "com.sovagrid.app", "data"],
        text=True).strip())
    expected = (folder / "remote-files/files-fixture.bin").read_bytes()
    candidates = list(container.glob("tmp/SovaGrid-SFTP-*/files-fixture.bin"))
    if not any(candidate.read_bytes() == expected for candidate in candidates):
        raise RuntimeError(
            f"Downloaded binary was not found or differed in the Simulator app container; "
            f"see {folder / 'test05BrowseAndDownloadSFTPOverJump.log'}")
    print(f"PASS SFTP ProxyJump binary download ({len(expected)} bytes)", flush=True)


def main():
    sftp_only = "--sftp-only" in sys.argv[1:]
    panel_only = "--panel-only" in sys.argv[1:]
    user = pwd.getpwuid(os.getuid()).pw_name
    folder = Path(tempfile.mkdtemp(prefix="sovagrid-panel-routes-"))
    simulator = None
    entry = target = web = blackhole = None
    handles = []
    try:
        # Fail before building if another service uses the fixed fixture ports.
        import socket
        for port in (ENTRY_PORT, TARGET_PORT, PANEL_PORT, BLACKHOLE_PORT):
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", port))
                except OSError as error:
                    raise RuntimeError(f"Fixture port {port} unavailable: {error}") from error
        runtime, device_type = simulator_type()
        simulator = subprocess.check_output([
            "xcrun", "simctl", "create", "SovaGrid panel route fixture",
            device_type, runtime], text=True).strip()
        run("xcrun", "simctl", "boot", simulator)
        run("xcrun", "simctl", "bootstatus", simulator, "-b", log=folder / "boot.log")

        run("xcodebuild", "build", "-project", str(ROOT / "SovaGrid.xcodeproj"),
            "-scheme", "SovaGrid", "-configuration", "Debug",
            "-destination", f"platform=iOS Simulator,id={simulator}",
            "-derivedDataPath", str(folder / "app-build"),
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", log=folder / "app-build.log")
        app = folder / "app-build/Build/Products/Debug-iphonesimulator/SovaGrid.app"
        run("xcrun", "simctl", "install", simulator, str(app))

        project = folder / "Smoke.xcodeproj"
        shutil.copytree(HERE / "Smoke.xcodeproj", project)
        (folder / "SmokeTests").mkdir()
        source = (HERE / "SmokeTests/SmokeTests.swift").read_text()
        (folder / "SmokeTests/SmokeTests.swift").write_text(
            source.replace('"__FIXTURE_USER__"', json.dumps(user))
                  .replace('"__FIXTURE_PATH__"', json.dumps(str(folder / "remote-files"))))

        panel = folder / "sovagrid/monitoring"
        panel.mkdir(parents=True)
        legacy_page = ("<html><head><title>SovaGrid</title></head><body>"
                       "<span>LOCAL PANEL FIXTURE</span>"
                       "<button onclick=\"fetch('/_fixture/custom-path').then(() => location.reload())\">"
                       "Change panel route</button></body></html>\n")
        (panel / "index.html").write_text(legacy_page)
        (panel / "manifest.webmanifest").write_text(json.dumps({"name": "SovaGrid panel fixture"}))
        custom_panel = folder / "ops/panel"
        custom_panel.mkdir(parents=True)
        (custom_panel / "index.html").write_text(
            "<html><head><title>SovaGrid</title></head><body>"
            "<span>LOCAL PANEL FIXTURE</span><span>CUSTOM PANEL FIXTURE</span>"
            "</body></html>\n")
        (custom_panel / "manifest.webmanifest").write_text(json.dumps({"name": "SovaGrid panel fixture"}))
        web_log = (folder / "web.log").open("w")
        handles.append(web_log)
        web = subprocess.Popen([sys.executable, str(HERE / "panel_http_fixture.py"),
                                str(folder), str(PANEL_PORT)],
                               stdout=web_log, stderr=subprocess.STDOUT)
        time.sleep(0.5)
        if web.poll() is not None:
            raise RuntimeError(f"HTTP fixture exited early; see {folder / 'web.log'}")

        for name in ("entry", "target"):
            run(SSH_KEYGEN, "-q", "-t", "ed25519", "-N", "", "-f", str(folder / f"{name}-host"))
            (folder / f"{name}-authorized").write_text("")
        entry_config = make_sshd_config(folder, "entry", ENTRY_PORT, user, "any",
                                        force_command=not sftp_only)
        target_config = make_sshd_config(folder, "target", TARGET_PORT, user, "any",
                                         force_command=not sftp_only)
        entry, handle = start_sshd(entry_config, folder / "entry.log")
        handles.append(handle)
        target, handle = start_sshd(target_config, folder / "target.log")
        handles.append(handle)

        output = test_case(project, folder, simulator, "test01CreateRouteProfileAndCaptureKeys")
        for name in ("entry", "target"):
            match = re.search(rf"SOVAGRID_ROUTE_{name.upper()}_PUBLIC_KEY=(ssh-ed25519 [A-Za-z0-9+/=]+)", output)
            if not match:
                raise RuntimeError(f"App public key for {name} missing; see test01 log in {folder}")
            (folder / f"{name}-authorized").write_text(match.group(1) + "\n")

        if sftp_only:
            (folder / "remote-files").mkdir()
            (folder / "remote-files/files-fixture.bin").write_bytes(
                bytes([0, 1, 2, 0, 255, 128]) + bytes(i % 251 for i in range(30000)))
            test_case(project, folder, simulator, "test05BrowseAndDownloadSFTPOverJump")
            verify_sftp_download(folder, simulator)
            print("SFTP via ProxyJump passed.", flush=True)
            return

        test_case(project, folder, simulator, "test02OpenEntryPanelAndReadPassword")
        # The next SSH connection must wait through 503 and open the advertised
        # custom route, while the first connection covers the legacy 404 path.
        with urllib.request.urlopen(f"http://127.0.0.1:{PANEL_PORT}/_fixture/custom-path", timeout=2) as response:
            if response.status != 200:
                raise RuntimeError("Could not switch panel route fixture")
        stop_process(entry)
        handles[1].close()
        # The entry host now refuses direct-tcpip to its own Hub port. A working
        # target WebView must therefore traverse the second SSH session.
        entry_config = make_sshd_config(folder, "entry", ENTRY_PORT, user,
                                        f"127.0.0.1:{TARGET_PORT}")
        entry, handle = start_sshd(entry_config, folder / "entry-restricted.log")
        handles.append(handle)
        test_case(project, folder, simulator, "test03OpenTargetPanelAndReadPassword")
        if panel_only:
            print("Legacy and custom panel routes through iPhone Simulator passed.", flush=True)
            return
        blackhole_log = (folder / "blackhole.log").open("w")
        handles.append(blackhole_log)
        blackhole = subprocess.Popen([
            sys.executable, "-u", "-c",
            "import socket, time\n"
            "s = socket.socket()\n"
            "s.bind(('127.0.0.1', 22223))\n"
            "s.listen()\n"
            "held = []\n"
            "while True:\n"
            "    client, _ = s.accept()\n"
            "    held.append(client)\n",
        ], stdout=blackhole_log, stderr=subprocess.STDOUT)
        time.sleep(0.5)
        if blackhole.poll() is not None:
            raise RuntimeError(f"Blackhole fixture exited early; see {folder / 'blackhole.log'}")
        test_case(project, folder, simulator, "test04StalledSSHConnectionTimesOut")
        stop_process(entry)
        stop_process(target)
        handles[2].close()
        handles[3].close()
        (folder / "remote-files").mkdir()
        (folder / "remote-files/files-fixture.bin").write_bytes(
            bytes([0, 1, 2, 0, 255, 128]) + bytes(i % 251 for i in range(30000)))
        entry_config = make_sshd_config(folder, "entry", ENTRY_PORT, user,
                                        f"127.0.0.1:{TARGET_PORT}", force_command=False)
        target_config = make_sshd_config(folder, "target", TARGET_PORT, user,
                                         "any", force_command=False)
        entry, handle = start_sshd(entry_config, folder / "entry-sftp.log")
        handles.append(handle)
        target, handle = start_sshd(target_config, folder / "target-sftp.log")
        handles.append(handle)
        test_case(project, folder, simulator, "test05BrowseAndDownloadSFTPOverJump")
        verify_sftp_download(folder, simulator)
        print("Both panel routes, host keys, WebKit, SSH timeout, and SFTP via ProxyJump passed.", flush=True)
    finally:
        for process in (entry, target, web, blackhole):
            stop_process(process)
        for handle in handles:
            handle.close()
        if simulator:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "delete", simulator],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for generated in ("app-build", "test-build"):
            shutil.rmtree(folder / generated, ignore_errors=True)
        for name in ("entry-host", "target-host", "entry-authorized", "target-authorized"):
            (folder / name).unlink(missing_ok=True)
        print(f"Fixture logs: {folder}")


if __name__ == "__main__":
    main()
