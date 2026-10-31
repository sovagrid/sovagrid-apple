// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

enum FirstInstallState { case none, running, done, failed, unknown }
struct FirstInstallJob {
    let state: FirstInstallState
    let stage: String
    let reason: String
    init(_ state: FirstInstallState, stage: String = "", reason: String = "") {
        self.state = state
        self.stage = stage
        self.reason = reason
    }
}

/// Fixed systemd job survives an app background transition. All status reads are read-only.
enum SovaGridFirstInstall {
    static let version = "0.11.0"
    static let sourceSHA256 = "10abb18ca39d789d3a9cc8bd04d36126f6dd624a81e48219bd814fb6a15ab766"
    static let manifestSHA256 = "a0e34d21e059ed6519710b7c441e995f390eca93fdf809aaea7da688d9e67389"
    static let maximumOutputBytes = 160
    private static let stages: Set<String> = ["START", "DOWNLOAD", "VERIFY", "EXTRACT", "RUN", "CHECK"]
    private static let reasons: Set<String> = ["ROOT", "UBUNTU", "EXISTING", "UNKNOWN", "DOWNLOAD", "DOWNLOAD_TOOL", "HASH", "ARCHIVE", "LAYOUT", "STAGE", "RUN", "RESULT", "INTERRUPTED"]
    private static let jobScript = """
        set -Eeuo pipefail
        umask 077
        job_dir=/var/lib/sovagrid-first-install
        stage_code=START
        reason=INTERRUPTED
        state=running
        write_status() {
          local temporary
          temporary=$(mktemp "$job_dir/.status.XXXXXXXX") || return 1
          printf 'SG_INSTALL_JOB_V1:%s:%s:%s\\n' "$1" "$2" "$3" > "$temporary"
          chmod 0600 "$temporary"
          mv -f -- "$temporary" "$job_dir/status"
        }
        refuse() {
          reason=$1
          if [[ -d $job_dir && ! -L $job_dir ]]; then write_status failed "$stage_code" "$reason" || true; fi
          exit 30
        }
        status_stage() {
          stage_code=$1
          write_status running "$stage_code" NONE || exit 31
        }
        finish_status() {
          if [[ $state != done && -d $job_dir && ! -L $job_dir ]]; then
            write_status failed "$stage_code" "$reason" || true
          fi
        }
        check_empty() {
          [[ $(id -u) == 0 ]] || refuse ROOT
          [[ -r /etc/os-release ]] || refuse UBUNTU
          . /etc/os-release
          [[ ${ID:-} == ubuntu ]] || refuse UBUNTU
          for path in /opt/sovagrid-src /opt/sovagrid-agent /opt/sovagrid-vpn /opt/sovagrid-agent-installer /etc/sovagrid /etc/sovagrid-hub /etc/sovagrid-agent-tunnel /etc/sovagrid-agent-tunnel-public /var/lib/sovagrid /var/lib/sovagrid-agent /var/lib/sovagrid-agent-enrollment /var/lib/sovagrid-hub-tunnels; do
            [[ ! -e $path && ! -L $path ]] || refuse EXISTING
          done
          for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system; do
            for path in "$base"/sovagrid-*; do
              [[ $path == */sovagrid-first-install.service ]] && continue
              [[ ! -e $path && ! -L $path ]] || refuse EXISTING
            done
          done
          if command -v docker >/dev/null 2>&1; then
            command -v timeout >/dev/null 2>&1 || refuse UNKNOWN
            projects=$(timeout 4 docker ps -a --filter label=com.docker.compose.project=sovagrid --format '{{.ID}}' 2>/dev/null) || refuse UNKNOWN
            [[ -z $projects ]] || refuse EXISTING
          fi
        }
        [[ ! -L /run/sovagrid-first-install.lock ]] || exit 32
        exec 9>/run/sovagrid-first-install.lock
        flock -n 9 || exit 33
        check_empty
        [[ ! -e $job_dir && ! -L $job_dir ]] || exit 34
        mkdir -m 0700 -- "$job_dir" || exit 35
        trap finish_status EXIT
        status_stage START
        archive=$(mktemp /opt/.sovagrid-mobile-bundle.XXXXXXXX) || refuse STAGE
        stage_dir=$(mktemp -d /opt/.sovagrid-mobile-stage.XXXXXXXX) || { rm -f -- "$archive"; refuse STAGE; }
        cleanup() { rm -f -- "$archive"; if [[ -d $stage_dir ]]; then rm -rf -- "$stage_dir"; fi; }
        trap 'cleanup || true; finish_status' EXIT
        url='https://github.com/sovagrid/sovagrid-blueprint/releases/download/server-v0.11.0/SovaGrid-server-source.tar.gz'
        expected='10abb18ca39d789d3a9cc8bd04d36126f6dd624a81e48219bd814fb6a15ab766'
        manifest='a0e34d21e059ed6519710b7c441e995f390eca93fdf809aaea7da688d9e67389'
        status_stage DOWNLOAD
        if command -v curl >/dev/null 2>&1; then
          curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --max-filesize 67108864 --output "$archive" "$url" >/dev/null 2>&1 || refuse DOWNLOAD
        elif command -v wget >/dev/null 2>&1; then
          timeout 180 bash -o pipefail -c 'wget --quiet --https-only --output-document=- "$1" | head -c 67108865 > "$2"' sovagrid "$url" "$archive" >/dev/null 2>&1 || refuse DOWNLOAD
        elif command -v python3 >/dev/null 2>&1; then
          python3 - "$archive" <<'PY' >/dev/null 2>&1 || refuse DOWNLOAD
        import sys
        import urllib.request
        url = 'https://github.com/sovagrid/sovagrid-blueprint/releases/download/server-v0.11.0/SovaGrid-server-source.tar.gz'
        with urllib.request.urlopen(url, timeout=30) as source, open(sys.argv[1], 'wb') as target:
            if not source.url.startswith('https://'):
                raise SystemExit(1)
            total = 0
            while True:
                block = source.read(65536)
                if not block:
                    break
                total += len(block)
                if total > 67108864:
                    raise SystemExit(1)
                target.write(block)
        PY
        else
          refuse DOWNLOAD_TOOL
        fi
        status_stage VERIFY
        [[ -s $archive && $(stat -c %s "$archive") -le 67108864 ]] || refuse HASH
        [[ $(sha256sum "$archive" | cut -d' ' -f1) == "$expected" ]] || refuse HASH
        check_empty
        tar --no-same-owner --same-permissions -xzf "$archive" -C "$stage_dir" >/dev/null 2>&1 || refuse ARCHIVE
        status_stage EXTRACT
        for component in sovagrid-blueprint sovagrid-hub sovagrid-web sovagrid-agent sovagrid-vpn; do
          [[ -d $stage_dir/$component && ! -L $stage_dir/$component ]] || refuse LAYOUT
        done
        for required in sovagrid-blueprint/run.sh sovagrid-blueprint/deploy/compose.yaml sovagrid-hub/Dockerfile sovagrid-web/Dockerfile sovagrid-web/deploy/Caddyfile.container sovagrid-agent/deploy/sovagrid-agent.service sovagrid-vpn/deploy/sovagrid-vpn-status.service sovagrid-bundle.json; do
          [[ -f $stage_dir/$required && ! -L $stage_dir/$required ]] || refuse LAYOUT
        done
        [[ $(find "$stage_dir" -mindepth 1 -maxdepth 1 -print | wc -l) -eq 6 ]] || refuse LAYOUT
        [[ -z $(find "$stage_dir" ! -type f ! -type d -print -quit) ]] || refuse LAYOUT
        [[ -z $(find "$stage_dir" -mindepth 1 -type d ! -perm 0755 -print -quit) ]] || refuse LAYOUT
        [[ -z $(find "$stage_dir" -type f ! -perm 0644 ! -perm 0755 -print -quit) ]] || refuse LAYOUT
        [[ $(sha256sum "$stage_dir/sovagrid-bundle.json" | cut -d' ' -f1) == "$manifest" ]] || refuse HASH
        check_empty
        mv -T -- "$stage_dir" /opt/sovagrid-src || refuse STAGE
        status_stage RUN
        bash /opt/sovagrid-src/sovagrid-blueprint/run.sh > "$job_dir/install.log" 2>&1 || refuse RUN
        status_stage CHECK
        [[ -f /var/lib/sovagrid/.managed-by-run-sh && ! -L /var/lib/sovagrid/.managed-by-run-sh ]] || refuse RESULT
        [[ $(sha256sum /opt/sovagrid-src/sovagrid-bundle.json | cut -d' ' -f1) == "$manifest" ]] || refuse HASH
        systemctl is-active --quiet sovagrid-agent.service || refuse RESULT
        python3 -c 'import urllib.request; r=urllib.request.urlopen("http://127.0.0.1:8766/healthz", timeout=5); assert r.status == 200; r.close()' >/dev/null 2>&1 || refuse RESULT
        write_status done DONE NONE || exit 36
        state=done
        """
    private static let statusScript = """
        set -eu
        job_dir=/var/lib/sovagrid-first-install
        unit=sovagrid-first-install.service
        active() {
          unit_state=$(systemctl is-active "$unit" 2>/dev/null || true)
          [ "$unit_state" = active ] || [ "$unit_state" = activating ]
        }
        if [ ! -e "$job_dir" ] && [ ! -L "$job_dir" ]; then
          if active; then printf 'SG_INSTALL_JOB_V1:running:START:NONE\\n';
          else printf 'SG_INSTALL_JOB_V1:none\\n'; fi
          exit 0
        fi
        if [ -L "$job_dir" ] || [ ! -d "$job_dir" ] ||
           [ "$(stat -c '%u:%a' "$job_dir" 2>/dev/null)" != '0:700' ]; then
          printf 'SG_INSTALL_JOB_V1:unknown\\n'; exit 0
        fi
        status="$job_dir/status"
        if [ ! -e "$status" ] && [ ! -L "$status" ]; then
          if active; then printf 'SG_INSTALL_JOB_V1:running:START:NONE\\n';
          else printf 'SG_INSTALL_JOB_V1:failed:START:INTERRUPTED\\n'; fi
          exit 0
        fi
        if [ -L "$status" ] || [ ! -f "$status" ] ||
           [ "$(stat -c '%u:%a:%h' "$status" 2>/dev/null)" != '0:600:1' ] ||
           [ "$(stat -c %s "$status" 2>/dev/null)" -gt 128 ]; then
          printf 'SG_INSTALL_JOB_V1:unknown\\n'; exit 0
        fi
        value=$(cat "$status") || { printf 'SG_INSTALL_JOB_V1:unknown\\n'; exit 0; }
        case "$value" in
          SG_INSTALL_JOB_V1:running:START:NONE|SG_INSTALL_JOB_V1:running:DOWNLOAD:NONE|SG_INSTALL_JOB_V1:running:VERIFY:NONE|SG_INSTALL_JOB_V1:running:EXTRACT:NONE|SG_INSTALL_JOB_V1:running:RUN:NONE|SG_INSTALL_JOB_V1:running:CHECK:NONE)
            if active; then printf '%s\\n' "$value";
            else printf 'SG_INSTALL_JOB_V1:failed:START:INTERRUPTED\\n'; fi ;;
          SG_INSTALL_JOB_V1:done:DONE:NONE) printf '%s\\n' "$value" ;;
          SG_INSTALL_JOB_V1:failed:*)
            case "$value" in
              *:ROOT|*:UBUNTU|*:EXISTING|*:UNKNOWN|*:DOWNLOAD|*:DOWNLOAD_TOOL|*:HASH|*:ARCHIVE|*:LAYOUT|*:STAGE|*:RUN|*:RESULT|*:INTERRUPTED) printf '%s\\n' "$value" ;;
              *) printf 'SG_INSTALL_JOB_V1:unknown\\n' ;;
            esac ;;
          *) printf 'SG_INSTALL_JOB_V1:unknown\\n' ;;
        esac
        """
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let startCommand: String = """
        if [ "$(id -u)" != 0 ]; then exit 1; fi; \
        if [ -e /var/lib/sovagrid-first-install ] || [ -L /var/lib/sovagrid-first-install ]; then exit 2; fi; \
        systemd-run --quiet --collect --unit=sovagrid-first-install --property=Type=exec --property=RuntimeMaxSec=2700 --property=StandardOutput=null --property=StandardError=null /bin/bash -c \(shellQuote(jobScript)) >/dev/null 2>&1 || exit 3; \
        printf 'SG_INSTALL_START_V1:OK\\n'
        """
    static let statusCommand: String = """
        if [ "$(id -u)" = 0 ]; then /bin/sh -c \(shellQuote(statusScript)); \
        elif command -v sudo >/dev/null 2>&1; then sudo -n /bin/sh -c \(shellQuote(statusScript)) 2>/dev/null || printf 'SG_INSTALL_JOB_V1:unknown\\n'; \
        else printf 'SG_INSTALL_JOB_V1:unknown\\n'; fi
        """

    static func startAccepted(_ output: [UInt8], exitStatus: Int?) -> Bool {
        exitStatus == 0 && output == Array("SG_INSTALL_START_V1:OK\n".utf8)
    }

    static func parseStatus(_ output: [UInt8], exitStatus: Int?) -> FirstInstallJob {
        guard exitStatus == 0, (1...maximumOutputBytes).contains(output.count),
              let text = String(bytes: output, encoding: .ascii), text.hasSuffix("\n") else {
            return FirstInstallJob(.unknown)
        }
        let line = String(text.dropLast())
        guard !line.contains("\n"), !line.contains("\r"), line.hasPrefix("SG_INSTALL_JOB_V1:") else {
            return FirstInstallJob(.unknown)
        }
        let parts = line.split(separator: ":").map(String.init)
        if parts == ["SG_INSTALL_JOB_V1", "none"] { return FirstInstallJob(.none) }
        if parts == ["SG_INSTALL_JOB_V1", "unknown"] { return FirstInstallJob(.unknown) }
        if parts == ["SG_INSTALL_JOB_V1", "done", "DONE", "NONE"] {
            return FirstInstallJob(.done, stage: "DONE")
        }
        guard parts.count == 4, parts[0] == "SG_INSTALL_JOB_V1", stages.contains(parts[2]) else {
            return FirstInstallJob(.unknown)
        }
        if parts[1] == "running", parts[3] == "NONE" {
            return FirstInstallJob(.running, stage: parts[2])
        }
        if parts[1] == "failed", reasons.contains(parts[3]) {
            return FirstInstallJob(.failed, stage: parts[2], reason: parts[3])
        }
        return FirstInstallJob(.unknown)
    }

    static func stageText(_ stage: String) -> String {
        switch stage {
        case "START": return "Установка запускается на сервере…"
        case "DOWNLOAD": return "Сервер загружает проверенный пакет…"
        case "VERIFY": return "Проверяем SHA-256 пакета…"
        case "EXTRACT": return "Распаковываем серверную часть…"
        case "RUN": return "Устанавливаем Hub и Agent…"
        case "CHECK": return "Проверяем работу панели и Agent…"
        default: return "Проверяем состояние установки…"
        }
    }

    static func failureText(_ reason: String) -> String {
        switch reason {
        case "ROOT": return "Для первой установки нужен вход root по SSH."
        case "UBUNTU": return "Первая установка поддерживает Ubuntu."
        case "EXISTING": return "На сервере уже есть SovaGrid или заняты его служебные пути."
        case "DOWNLOAD", "DOWNLOAD_TOOL": return "Сервер не смог загрузить пакет. Проверьте доступ к GitHub."
        case "HASH": return "Пакет или манифест не совпали с проверенным SHA-256."
        case "ARCHIVE", "LAYOUT": return "Сервер отклонил структуру пакета."
        case "RUN", "RESULT": return "Установка началась, но Hub не прошёл проверку. Проверьте сервер перед повторением."
        default: return "Установка прервалась. Проверьте сервер перед повторением."
        }
    }
}
