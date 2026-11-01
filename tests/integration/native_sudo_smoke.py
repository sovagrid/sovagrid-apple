#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Jigokuraku01
# Additional author attribution terms: see ATTRIBUTION.md.
"""Verify exact client commands using real sudo in one disposable Ubuntu container.

The target is a CLI argument, never embedded in source/report. Docker is pinned to
that SSH host's local Unix socket. No host networking, ports, mounts or privileges
are requested. A root-owned systemd-run stub records argv instead of installing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import signal
import subprocess
import uuid

PASSWORD = b"SOVAGRID_FIXTURE_PASSWORD_0123456789\n"
DOCKER = ["/usr/bin/env", "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT", "-u", "DOCKER_TLS_VERIFY",
          "-u", "DOCKER_CERT_PATH", "/usr/bin/docker", "--host", "unix:///var/run/docker.sock"]
SETUP = r'''set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends sudo >/dev/null
useradd -m -s /bin/sh sgnative-admin
useradd -m -s /bin/sh sgnative-denied
printf '%s\n' 'sgnative-admin ALL=(root) NOPASSWD: ALL' > /etc/sudoers.d/sgnative-smoke
chmod 0440 /etc/sudoers.d/sgnative-smoke
cat > /usr/local/bin/systemd-run <<'STUB'
#!/bin/sh
set -eu
umask 077
[ "$(/usr/bin/id -u)" = 0 ] || exit 41
printf '%s\000' "$@" > /tmp/sgnative-argv
printf '1\n' >> /tmp/sgnative-calls
mkdir -m 0700 /var/lib/sovagrid-first-install
printf 'SG_INSTALL_JOB_V1:running:START:NONE\n' > /var/lib/sovagrid-first-install/status
STUB
chmod 0755 /usr/local/bin/systemd-run
cat > /usr/local/bin/systemctl <<'STUB'
#!/bin/sh
if [ "$*" = 'is-active sovagrid-first-install.service' ] && [ -d /var/lib/sovagrid-first-install ]; then
 printf 'active\n'; exit 0
fi
printf 'inactive\n'; exit 3
STUB
chmod 0755 /usr/local/bin/systemctl
'''
RESET = "rm -rf -- /var/lib/sovagrid-first-install /etc/sovagrid /tmp/sgnative-argv /tmp/sgnative-calls"


def shell_tokens(script):
    lexer = shlex.shlex(script, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def expected_job(command):
    outer = shell_tokens(command)
    assert outer[:4] == ["set", "--", "/bin/sh", "-c"]
    inner = shell_tokens(outer[4])
    index = inner.index("systemd-run")
    index = inner.index("/bin/bash", index)
    assert inner[index + 1] == "-c"
    job = inner[index + 2]
    assert "SOVAGRID_INSTALLATION_LOCK_FD=6" in job and "check_empty" in job
    return job.encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-host", required=True)
    parser.add_argument("--ssh-identity", type=Path)
    parser.add_argument("--commands-dir", action="append", type=Path, required=True)
    parser.add_argument("--elevation-command", type=Path,
                        help="Optional exact client wrapper around '/usr/bin/id -u; /bin/cat'")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    assert re.fullmatch(r"[A-Za-z0-9_.:@\[\]-]{1,255}", args.ssh_host) and not args.ssh_host.startswith("-")
    ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]
    if args.ssh_identity: ssh += ["-i", str(args.ssh_identity)]
    ssh += ["--", args.ssh_host]
    nonce = uuid.uuid4().hex
    name = "sg-native-sudo-" + nonce
    report = {"protocol": 1, "image": "ubuntu:24.04", "clients": []}

    def remote(parts, body=None, timeout=60, check=True):
        result = subprocess.run(ssh + [shlex.join(parts)], input=body, capture_output=True, timeout=timeout)
        if check and result.returncode:
            # Never include the target, SSH key path or raw command in a report.
            detail = result.stderr[-1500:].decode(errors="replace")
            for value in (args.ssh_host, args.ssh_host.split("@")[-1], str(args.ssh_identity or "")):
                if value: detail = detail.replace(value, "[redacted]")
            raise RuntimeError(f"Remote container operation failed ({result.returncode}): {detail}")
        return result

    def docker(*parts, body=None, timeout=60, check=True):
        return remote(DOCKER + list(parts), body, timeout, check)

    def execute(user, command, check=True):
        return docker("exec", "-i", "--user", user, name, "/bin/sh", "-s", body=command.encode(), check=check)

    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        docker("run", "--detach", "--rm", "--name", name, "--label", "sg-test=" + nonce,
               "--memory", "256m", "--cpus", "0.5", "--pids-limit", "128", "--stop-timeout", "3",
               "ubuntu:24.04", "/bin/sleep", "600", timeout=180)
        docker("exec", "-i", "--user", "root", name, "/bin/sh", "-s", body=SETUP.encode(), timeout=240)
        for directory in args.commands_dir:
            assert re.fullmatch(r"[A-Za-z0-9_-]{1,48}", directory.name)
            commands = {part: (directory / (part + ".command")).read_text()
                        for part in ("start", "status", "probe", "password")}
            assert all(0 < len(value.encode()) < 65536 and "\x00" not in value for value in commands.values())
            job = expected_job(commands["start"])
            client = {"client": directory.name, "job_sha256": hashlib.sha256(job).hexdigest(), "checks": []}
            execute("root", RESET)
            assert execute("root", commands["probe"]).stdout == b"SG_STATUS_V1:missing\n"
            assert execute("sgnative-admin", commands["probe"]).stdout == b"SG_STATUS_V1:missing\n"
            assert execute("sgnative-denied", commands["probe"]).stdout == b"SG_STATUS_V1:unknown\n"
            client["checks"].append("privileged-clean-probe")
            for user in ("root", "sgnative-admin"):
                execute("root", RESET)
                assert execute(user, commands["status"]).stdout == b"SG_INSTALL_JOB_V1:none\n"
                assert execute(user, commands["start"]).stdout == b"SG_INSTALL_START_V1:OK\n"
                argv = docker("exec", "--user", "root", name, "/bin/cat", "/tmp/sgnative-argv").stdout.split(b"\x00")[:-1]
                assert argv[-3:] == [b"/bin/bash", b"-c", job]
                assert b"--unit=sovagrid-first-install" in argv and b"--property=RuntimeMaxSec=2700" in argv
                assert execute(user, commands["status"]).stdout == b"SG_INSTALL_JOB_V1:running:START:NONE\n"
                duplicate = execute(user, commands["start"], check=False)
                assert duplicate.returncode != 0 and b"SG_INSTALL_START_V1:OK" not in duplicate.stdout
                assert docker("exec", "--user", "root", name, "/bin/cat", "/tmp/sgnative-calls").stdout == b"1\n"
            client["checks"].append("root-and-sudo-start-exact-argv-status-duplicate-refusal")
            execute("root", RESET)
            denied = execute("sgnative-denied", commands["start"], check=False)
            assert denied.returncode != 0 and b"SG_INSTALL_START_V1:OK" not in denied.stdout
            assert execute("sgnative-denied", commands["status"]).stdout == b"SG_INSTALL_JOB_V1:unknown\n"
            assert execute("root", "test ! -e /tmp/sgnative-calls").returncode == 0
            client["checks"].append("denied-user-cannot-start-or-read-root-status")
            execute("root", "umask 077; mkdir -m 0700 /etc/sovagrid; printf '%s\\n' SOVAGRID_FIXTURE_PASSWORD_0123456789 > /etc/sovagrid/admin-password")
            for user in ("root", "sgnative-admin"):
                assert execute(user, commands["password"]).stdout == PASSWORD
            denied = execute("sgnative-denied", commands["password"], check=False)
            assert denied.returncode != 0 and PASSWORD.strip() not in denied.stdout
            client["checks"].append("initial-password-root-sudo-only")
            report["clients"].append(client)
            print("PASS", directory.name, ", ".join(client["checks"]), flush=True)
        if args.elevation_command:
            command = args.elevation_command.read_text()
            assert 0 < len(command.encode()) < 65536 and "\x00" not in command
            fixture = b"\x00SOVAGRID_BINARY_STDIN\xff\n"
            for user in ("root", "sgnative-admin"):
                result = docker("exec", "-i", "--user", user, name, "/bin/sh", "-c", command, body=fixture)
                assert result.stdout == b"0\n" + fixture
            result = docker("exec", "-i", "--user", "sgnative-denied", name,
                            "/bin/sh", "-c", command, body=fixture, check=False)
            assert result.returncode != 0 and fixture not in result.stdout
            report["elevation_command"] = {"sha256": hashlib.sha256(command.encode()).hexdigest(),
                                            "checks": ["root-and-sudo-binary-stdin", "denied-user-refused"]}
            print("PASS exact client elevation wrapper preserves binary stdin; denied user refused", flush=True)
        if args.report:
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        print("PASS disposable Ubuntu elevation smoke; no backend job was executed", flush=True)
    finally:
        exists = docker("inspect", "--format", '{{index .Config.Labels "sg-test"}}', name, timeout=20, check=False)
        if exists.returncode == 0 and exists.stdout.strip() == nonce.encode():
            docker("rm", "--force", name, timeout=30)
            print("Removed test container", flush=True)

if __name__ == "__main__":
    main()
