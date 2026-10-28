#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Jigokuraku01
# Additional author attribution terms: see ATTRIBUTION.md.
"""Exercise Apple's fixed detached installer on a disposable Ubuntu CI VM.

The commands come from compiled Swift, so this job tests what the app sends
over SSH. No user host, SSH credential, or release token is involved.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import time
import urllib.request


ROOT = Path(os.environ["SOVAGRID_CI_INSTALL_COMMAND_DIR"])
EXPECTED_BUNDLE = "275c5f03c30b1a924b1fcb48067a41f7b76481cd4c249589a7c8b5098db749fb"
EXPECTED_MANIFEST = "2314f9b66ca1d70dba1e348ceb93e99367c5a074ceb370dc307f0dab4a877a03"
STATUS = re.compile(
    r"SG_INSTALL_JOB_V1:(?:none|unknown|done:DONE:NONE|"
    r"running:(?:START|DOWNLOAD|VERIFY|EXTRACT|RUN|CHECK):NONE|"
    r"failed:(?:START|DOWNLOAD|VERIFY|EXTRACT|RUN|CHECK):"
    r"(?:ROOT|UBUNTU|EXISTING|UNKNOWN|DOWNLOAD|DOWNLOAD_TOOL|HASH|ARCHIVE|"
    r"LAYOUT|STAGE|RUN|RESULT|INTERRUPTED))\n\Z"
)


def require(value: bool, message: str) -> None:
    if not value:
        raise RuntimeError(message)


def sudo_shell(command: str, *, timeout: int = 60,
               max_stdout: int = 256) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(["sudo", "-n", "/bin/bash", "-c", command],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False)
    require(len(result.stdout) <= max_stdout and len(result.stderr) <= 4096,
            "Unexpectedly large response from CI VM")
    return result


def job_status(command: str) -> str:
    response = sudo_shell(command)
    require(response.returncode == 0, "Cannot read installer status on disposable CI VM")
    value = response.stdout.decode("ascii", errors="strict")
    require(STATUS.fullmatch(value) is not None, "Invalid installer status protocol")
    return value.strip().removeprefix("SG_INSTALL_JOB_V1:")


def health() -> None:
    manifest = sudo_shell("sha256sum /opt/sovagrid-src/sovagrid-bundle.json")
    require(manifest.returncode == 0 and manifest.stdout.split(b" ", 1)[0].decode() == EXPECTED_MANIFEST,
            "Installed source manifest differs from Apple's pin")
    require(sudo_shell("test -f /var/lib/sovagrid/.managed-by-run-sh").returncode == 0,
            "Managed install marker missing")
    require(sudo_shell("systemctl is-active --quiet sovagrid-agent.service").returncode == 0,
            "Agent service inactive")
    hub = sudo_shell("docker compose --env-file /etc/sovagrid/deploy.env "
                     "-f /opt/sovagrid-src/sovagrid-blueprint/deploy/compose.yaml "
                     "ps --status running --quiet hub")
    require(hub.returncode == 0 and hub.stdout.strip(), "Hub container inactive")
    with urllib.request.urlopen("http://127.0.0.1:8766/healthz", timeout=8) as response:
        require(response.status == 200, "Hub/Web health endpoint failed")
    with urllib.request.urlopen("http://127.0.0.1:8766/sovagrid/monitoring/", timeout=8) as response:
        body = response.read(128 * 1024)
        require(response.status == 200 and b"SovaGrid" in body,
                "Panel not served from the new independent Hub")


def print_safe_failure_summary() -> None:
    # The full root-private installer log may contain generated values. Surface
    # only bounded, recognizable diagnostics from this disposable VM.
    command = ("grep -E '^(SovaGrid:|E: |Error response from daemon:|"
               "ModuleNotFoundError:|ImportError:|OSError:|subprocess\\.CalledProcessError:)' "
               "/var/lib/sovagrid-first-install/install.log | tail -n 16")
    result = sudo_shell(command, max_stdout=4096)
    if result.returncode != 0:
        print("Installer diagnostic summary unavailable", flush=True)
        return
    for line in result.stdout.decode("utf-8", errors="replace").splitlines():
        safe = re.sub(r"[A-Za-z0-9_=-]{32,}", "[redacted]", line)
        safe = re.sub(r"https?://\S+", "[url]", safe)
        print("Installer diagnostic: " + safe[:240], flush=True)


def main() -> None:
    require(os.environ.get("GITHUB_ACTIONS") == "true", "Use only a disposable GitHub Actions VM")
    require(os.environ.get("RUNNER_OS") == "Linux", "Use only a disposable Linux CI VM")
    require(os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "Refusing to run on a self-hosted machine")
    require(ROOT.is_dir(), "Missing compiled Apple command directory")
    start = (ROOT / "start.command").read_text(encoding="utf-8")
    status = (ROOT / "status.command").read_text(encoding="utf-8")
    require(EXPECTED_BUNDLE in start and EXPECTED_MANIFEST in start,
            "Apple installer no longer pins the reviewed server bundle")
    require(job_status(status) == "none", "Disposable CI VM is not clean")

    started = sudo_shell(start)
    require(started.returncode == 0 and started.stdout == b"SG_INSTALL_START_V1:OK\n",
            "Detached installer did not start on disposable CI VM")
    print("Detached Apple installer started on disposable Ubuntu VM", flush=True)
    # A second request must not launch another root installation.
    duplicate = sudo_shell(start)
    require(duplicate.returncode != 0 and b"SG_INSTALL_START_V1:OK" not in duplicate.stdout,
            "Duplicate detached installer was accepted")

    deadline = time.monotonic() + 38 * 60
    previous = ""
    while time.monotonic() < deadline:
        value = job_status(status)
        if value != previous:
            print("Installer state: " + value, flush=True)
            previous = value
        if value == "done:DONE:NONE":
            health()
            again = sudo_shell(start)
            require(again.returncode != 0 and b"SG_INSTALL_START_V1:OK" not in again.stdout,
                    "Completed installer allowed a second root installation")
            print("CLEAN_UBUNTU_MOBILE_INSTALL_VERIFIED", flush=True)
            return
        if value.startswith("failed:") or value in {"unknown", "none"}:
            if value.startswith("failed:"):
                print_safe_failure_summary()
            raise RuntimeError("Detached installer ended without a verified Hub: " + value)
        time.sleep(12)
    raise RuntimeError("Detached installer exceeded the disposable CI VM deadline")


if __name__ == "__main__":
    main()
