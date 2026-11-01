// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// A root or passwordless-sudo read-only probe over the already trusted SSH channel.
enum ServerDeployment: String {
    case managed
    case agentOnly = "agent_only"
    case missing
    case conflict
    case unsupported
    case unknown

    static let maximumOutputBytes = 64

    static func parse(_ output: [UInt8], exitStatus: Int?) -> ServerDeployment {
        guard exitStatus == 0, (1...maximumOutputBytes).contains(output.count),
              let text = String(bytes: output, encoding: .ascii) else { return .unknown }
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard line.hasPrefix("SG_STATUS_V1:"), !line.contains("\n"), !line.contains("\r") else { return .unknown }
        return ServerDeployment(rawValue: String(line.dropFirst("SG_STATUS_V1:".count))) ?? .unknown
    }
}

/// Fixed command; host/profile values are never inserted. Unknown must not authorize installation.
enum ServerDeploymentProbe {
    // Same fixed, read-only predicate as Connect and the Web SSH gateway.
    private static let managedVPNSourceCheck = #"""

        def managed_vpn_source(root=None, owner=0):
            'Recognize only a root-owned, hash-closed Agent VPN extension; never execute it.'
            import hashlib
            import json
            import os
            from pathlib import Path
            import re
            import stat
            import time

            root = Path('/') if root is None else Path(root)
            descriptor = None
            deadline, consumed, visited = time.monotonic() + 5, 0, 0
            sha = re.compile(r'[0-9a-f]{64}\Z')
            part = re.compile(r'[A-Za-z0-9_.-]+\Z')
            stage = re.compile(r'/opt/\.sovagrid-vpn-source-[0-9a-f]{32}\Z')

            def need(value):
                if not value or time.monotonic() > deadline:
                    raise ValueError('invalid managed VPN namespace')

            def checked(fd, directory=False, mode=None):
                info = os.fstat(fd)
                need(info.st_uid == owner and not info.st_mode & 0o022 and
                     (stat.S_ISDIR(info.st_mode) if directory else
                      stat.S_ISREG(info.st_mode) and info.st_nlink == 1))
                need(mode is None or stat.S_IMODE(info.st_mode) == mode)
                return info

            def entries(fd, limit):
                names = []
                with os.scandir(fd) as iterator:
                    for entry in iterator:
                        need(len(names) < limit)
                        names.append(entry.name)
                return names

            def directory(path):
                fd = os.dup(descriptor)
                try:
                    for name in Path(path).parts[1:]:
                        need(part.fullmatch(name) is not None and name not in ('.', '..'))
                        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                        dir_fd=fd)
                        os.close(fd)
                        fd = child
                        checked(fd, directory=True)
                    return fd
                except BaseException:
                    os.close(fd)
                    raise

            def read(fd, name, limit, *, digest=False, mode=None, attempt=0):
                nonlocal consumed
                child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                dir_fd=fd)
                try:
                    before = checked(child, mode=mode)
                    need(before.st_size <= limit)
                    data, hashing, size = [], hashlib.sha256(), 0
                    while True:
                        block = os.read(child, min(65536, limit + 1 - size))
                        if not block:
                            break
                        size += len(block)
                        consumed += len(block)
                        need(size <= limit and consumed <= 512 * 1024 * 1024)
                        if digest:
                            hashing.update(block)
                        else:
                            data.append(block)
                    after = os.fstat(child)
                    if before.st_nlink == 1 and after.st_nlink == 0:
                        # A publisher can atomically replace its old inode while this
                        # descriptor is held. Read the new file; never accept old bytes.
                        current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        need(attempt < 2 and stat.S_ISREG(current.st_mode) and
                             current.st_uid == owner and current.st_nlink == 1 and not current.st_mode & 0o022 and
                             (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino))
                        return read(fd, name, limit, digest=digest, mode=mode, attempt=attempt + 1)
                    after = checked(child, mode=mode)
                    need((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                         (after.st_size, after.st_mtime_ns, after.st_ctime_ns) and size == before.st_size)
                    return hashing.hexdigest() if digest else b''.join(data)
                finally:
                    os.close(child)

            def closed(path, allowed, required=()):
                fd = directory(path)
                try:
                    names = set(entries(fd, 16))
                    need(set(required) <= names <= set(allowed))
                except BaseException:
                    os.close(fd)
                    raise
                return fd, names

            def unique(pairs):
                result = {}
                for key, value in pairs:
                    need(key not in result)
                    result[key] = value
                return result

            def document(raw):
                value = json.loads(raw, object_pairs_hook=unique)
                need(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                ensure_ascii=False, allow_nan=False).encode() == raw)
                return value

            def hashes(value):
                need(type(value) is dict and 1 <= len(value) <= 4096)
                for name, digest in value.items():
                    need(type(name) is str and len(name) <= 255 and
                         all(piece not in ('', '.', '..') and part.fullmatch(piece)
                             for piece in name.split('/')) and type(digest) is str and sha.fullmatch(digest))

            def receipt(value):
                need(type(value) is dict and set(value) == {'protocol', 'phase', 'source_manifest_sha256',
                     'source_files', 'package_files', 'garbage_stage'} and type(value['protocol']) is int and
                     value['protocol'] == 1 and value['phase'] == 'active' and
                     type(value['source_manifest_sha256']) is str and sha.fullmatch(value['source_manifest_sha256']))
                hashes(value['source_files'])
                hashes(value['package_files'])
                required = {'LICENSE', 'NOTICE', 'ATTRIBUTION.md', 'deploy/install-amnezia-control.py',
                    'deploy/install-wireguard-control.py', 'deploy/sovagrid-amnezia-provision',
                    'sovagrid_vpn/amnezia_install.py', 'sovagrid_vpn/amnezia_admin.py',
                    'sovagrid_vpn/amnezia_provision.py', 'sovagrid_vpn/wireguard_install.py'}
                need(required <= set(value['source_files']))
                need(value['package_files'] == {name.split('/')[1]: digest
                    for name, digest in value['source_files'].items()
                    if name.startswith('sovagrid_vpn/') and name.endswith('.py') and name.count('/') == 1})
                need(value['garbage_stage'] is None or type(value['garbage_stage']) is str and
                     stage.fullmatch(value['garbage_stage']))

            def tree(path, expected):
                directories = {''}
                caches = set()
                for name in expected:
                    parents = name.split('/')[:-1]
                    directories.update('/'.join(parents[:number]) for number in range(1, len(parents) + 1))
                    if name.endswith('.py'):
                        caches.add('/'.join(parents + ['__pycache__']))
                found = set()

                def walk(fd, prefix=''):
                    nonlocal visited
                    for name in entries(fd, 4096):
                        visited += 1
                        need(visited <= 16384 and part.fullmatch(name) and name not in ('.', '..'))
                        relative = prefix + name
                        if relative in directories or relative in caches:
                            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                            dir_fd=fd)
                            try:
                                checked(child, directory=True)
                                walk(child, relative + '/')
                            finally:
                                os.close(child)
                        elif relative in expected:
                            need(read(fd, name, 32 * 1024 * 1024, digest=True) == expected[relative])
                            found.add(relative)
                        else:
                            match = re.fullmatch(r'(.*?)(?:__pycache__/)([A-Za-z0-9_.-]+)\.cpython-[0-9]+\.pyc', relative)
                            need(match is not None and match[1] + match[2] + '.py' in expected)
                            read(fd, name, 32 * 1024 * 1024, digest=True)
                fd = directory(path)
                try:
                    walk(fd)
                    need(found == set(expected))
                finally:
                    os.close(fd)

            opened = []
            try:
                descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
                checked(descriptor, directory=True)
                for path, allowed, required in (
                    ('/opt/sovagrid-src', {'sovagrid-vpn'}, {'sovagrid-vpn'}),
                    ('/opt/sovagrid-vpn', {'sovagrid_vpn'}, {'sovagrid_vpn'}),
                    ('/var/lib/sovagrid', {'vpn-source', 'vpn'}, {'vpn-source'})):
                    fd, _names = closed(path, allowed, required)
                    opened.append(fd)
                fd, names = closed('/var/lib/sovagrid/vpn-source', {'state.json', '.lock'}, {'state.json'})
                opened.append(fd)
                checked(fd, directory=True, mode=0o700)
                raw = read(fd, 'state.json', 512 * 1024, mode=0o600)
                state = document(raw)
                receipt(state)
                if '.lock' in names:
                    need(read(fd, '.lock', 0, mode=0o600) == b'')
                tree('/opt/sovagrid-src/sovagrid-vpn', state['source_files'])
                tree('/opt/sovagrid-vpn/sovagrid_vpn', state['package_files'])
                if state['garbage_stage'] is not None:
                    try:
                        garbage = directory(state['garbage_stage'])
                    except FileNotFoundError:
                        pass
                    else:
                        try:
                            checked(garbage, directory=True, mode=0o700)
                        finally:
                            os.close(garbage)
                if 'vpn' in set(entries(opened[2], 16)):
                    vpn = directory('/var/lib/sovagrid/vpn')
                    opened.append(vpn)
                    for name in entries(vpn, 32):
                        need(name == 'status.json' or re.fullmatch(r'\.vpn-status-[A-Za-z0-9_]{8}', name))
                        if name != 'status.json':
                            try:
                                temporary = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                                    dir_fd=vpn)
                            except FileNotFoundError:
                                continue  # This known publisher scratch file was renamed.
                            try:
                                need(checked(temporary).st_size <= 65536)
                            finally:
                                os.close(temporary)
                            continue  # A scratch file may still contain incomplete JSON.
                        value = json.loads(read(vpn, name, 65536), object_pairs_hook=unique)
                        need(type(value) is dict and type(value.get('schema_version')) is int and value['schema_version'] == 1 and
                             type(value.get('collected_at')) is int and value['collected_at'] > 0)
                need(read(fd, 'state.json', 512 * 1024, mode=0o600) == raw)
                need(set(entries(opened[0], 16)) == {'sovagrid-vpn'} and
                     set(entries(opened[1], 16)) == {'sovagrid_vpn'} and
                     {'vpn-source'} <= set(entries(opened[2], 16)) <= {'vpn-source', 'vpn'} and
                     set(entries(fd, 16)) == names)
                return True
            except (OSError, ValueError, TypeError, KeyError, UnicodeError, RecursionError, AttributeError):
                return False
            finally:
                for fd in opened:
                    os.close(fd)
                if descriptor is not None:
                    os.close(descriptor)

        """#

    private static let script = """
        set -u
        if [ ! -r /etc/os-release ] || ! grep -Eq '^ID="?ubuntu"?$' /etc/os-release; then printf 'SG_STATUS_V1:unsupported\\n'; exit 0; fi
        for p in /opt/sovagrid-src /opt/sovagrid-agent /opt/sovagrid-vpn /opt/sovagrid-agent-installer /etc/sovagrid /etc/sovagrid-hub /etc/sovagrid-agent-tunnel /etc/sovagrid-agent-tunnel-public /var/lib/sovagrid /var/lib/sovagrid-agent /var/lib/sovagrid-agent-enrollment /var/lib/sovagrid-hub-tunnels /var/lib/sovagrid-first-install; do
          if [ -L "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        done
        if [ -d /opt/sovagrid-src ] && [ "$(stat -c %u /opt/sovagrid-src 2>/dev/null)" = 0 ] &&
           [ -f /opt/sovagrid-src/sovagrid-bundle.json ] && [ ! -L /opt/sovagrid-src/sovagrid-bundle.json ] &&
           [ "$(stat -c %u /opt/sovagrid-src/sovagrid-bundle.json 2>/dev/null)" = 0 ] &&
           [ -f /var/lib/sovagrid/.managed-by-run-sh ] && [ ! -L /var/lib/sovagrid/.managed-by-run-sh ] &&
           [ "$(stat -c %u /var/lib/sovagrid/.managed-by-run-sh 2>/dev/null)" = 0 ]; then
           printf 'SG_STATUS_V1:managed\\n'; exit 0; fi
        if [ -f /opt/sovagrid-agent-installer/source-manifest.json ] && [ ! -L /opt/sovagrid-agent-installer/source-manifest.json ] &&
           [ "$(stat -c %u /opt/sovagrid-agent-installer/source-manifest.json 2>/dev/null)" = 0 ] &&
           [ -f /etc/systemd/system/sovagrid-agent.service ] && [ ! -L /etc/systemd/system/sovagrid-agent.service ] &&
           [ "$(stat -c %u /etc/systemd/system/sovagrid-agent.service 2>/dev/null)" = 0 ] &&
           [ -d /var/lib/sovagrid-agent-enrollment ] &&
           [ "$(stat -c %u /var/lib/sovagrid-agent-enrollment 2>/dev/null)" = 0 ] &&
           [ ! -e /etc/sovagrid-hub ] && [ ! -e /etc/sovagrid/.agent-unit-managed-by-run-sh ]; then
          if [ ! -e /opt/sovagrid-src ] && [ ! -e /opt/sovagrid-vpn ] && [ ! -e /var/lib/sovagrid ]; then
            printf 'SG_STATUS_V1:agent_only\\n'; exit 0
          elif command -v python3 >/dev/null 2>&1; then
            if python3 -B -I - <<'SG_MANAGED_VPN_SOURCE'
        \(managedVPNSourceCheck)raise SystemExit(0 if managed_vpn_source() else 1)
        SG_MANAGED_VPN_SOURCE
            then
              printf 'SG_STATUS_V1:agent_only\\n'; exit 0
            fi
          fi
        fi
        for p in /opt/sovagrid-src /opt/sovagrid-agent /opt/sovagrid-vpn /opt/sovagrid-agent-installer /etc/sovagrid /etc/sovagrid-hub /etc/sovagrid-agent-tunnel /etc/sovagrid-agent-tunnel-public /var/lib/sovagrid /var/lib/sovagrid-agent /var/lib/sovagrid-agent-enrollment /var/lib/sovagrid-hub-tunnels /var/lib/sovagrid-first-install; do
           if [ -e "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        done
        for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system; do
           for p in "$base"/sovagrid-*; do
              if [ -e "$p" ] || [ -L "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
           done
        done
        if command -v docker >/dev/null 2>&1; then
           if ! command -v timeout >/dev/null 2>&1; then printf 'SG_STATUS_V1:unknown\\n'; exit 0; fi
           projects=$(timeout 4 docker ps -a --filter label=com.docker.compose.project=sovagrid --format '{{.ID}}' 2>/dev/null) || { printf 'SG_STATUS_V1:unknown\\n'; exit 0; }
           if [ -n "$projects" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        fi
        printf 'SG_STATUS_V1:missing\\n'
        """

    static let command: String = {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ \"$(/usr/bin/id -u)\" = 0 ]; then /bin/sh -c \(quoted); " +
            "elif [ -x /usr/bin/sudo ]; then " +
            "/usr/bin/sudo -n /bin/sh -c \(quoted) 2>/dev/null || printf 'SG_STATUS_V1:unknown\\n'; " +
            "else printf 'SG_STATUS_V1:unknown\\n'; fi"
    }()
}

/// A short-lived proof issued only through the selected server's authenticated SSH channel.
enum SSHGrantResponse {
    static let maximumOutputBytes = 512

    static let command = """
        if [ "$(/usr/bin/id -u)" = 0 ]; then
          docker compose --env-file /etc/sovagrid/deploy.env -f /opt/sovagrid-src/sovagrid-blueprint/deploy/compose.yaml run --rm --no-deps -T --entrypoint python3 hub -m sovagrid_hub --db /data/hub.sqlite ssh-grant
        elif [ -x /usr/bin/sudo ]; then
          /usr/bin/sudo -n docker compose --env-file /etc/sovagrid/deploy.env -f /opt/sovagrid-src/sovagrid-blueprint/deploy/compose.yaml run --rm --no-deps -T --entrypoint python3 hub -m sovagrid_hub --db /data/hub.sqlite ssh-grant
        else exit 1; fi
        """

    static func parse(_ output: [UInt8], exitStatus: Int?) -> String? {
        guard exitStatus == 0, (2...maximumOutputBytes).contains(output.count),
              let text = String(bytes: output, encoding: .utf8) else { return nil }
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !line.contains("\n"), !line.contains("\r"), !line.contains("\0"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["protocol", "grant", "expires_at", "username"]),
              let protocolNumber = object["protocol"] as? NSNumber,
              CFGetTypeID(protocolNumber) != CFBooleanGetTypeID(), protocolNumber.intValue == 1,
              let grant = object["grant"] as? String,
              grant.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let expiry = object["expires_at"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              (1_000_000_000...4_102_444_800).contains(expiry.int64Value),
              let username = object["username"] as? String,
              !username.isEmpty, username.count <= 80,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return grant
    }

    static func javaScriptLiteral(_ grant: String) -> String? {
        guard grant.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let data = try? JSONSerialization.data(withJSONObject: grant, options: .fragmentsAllowed)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
