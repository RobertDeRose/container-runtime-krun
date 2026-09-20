#!/usr/bin/env python3
"""Validate one native-libkrun NIC without installing, rebuilding, or falling back."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tarfile
import threading
import time
from typing import Any, Iterator
import urllib.request

from macho_trust import check_privileged_path, parse_load_commands, trusted_system_library

TRUSTED = Path('/Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun')
HELPER = TRUSTED / 'bin/container-krun-vmm-helper'
LIBRARY = TRUSTED / 'lib/libkrun.dylib'
PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANAGED_LIBKRUN = PROJECT_ROOT / '.build-deps/libkrun'


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def provenance(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition('=')
        require(bool(sep) and key not in values, f'invalid or duplicate provenance entry: {line!r}')
        values[key] = value
    for key in ('commit', 'source_build_sha256', 'sha256', 'helper_sha256', 'runtime_sha256'):
        length = 40 if key == 'commit' else 64
        require(bool(re.fullmatch(rf'[0-9a-f]{{{length}}}', values.get(key, ''))), f'invalid provenance {key}')
    require(values.get('source_dirty') == 'false', 'build did not record clean source')
    require(values.get('backend') == 'libkrun-vmnet-shared', 'installed provenance is not native vmnet')
    require(values.get('features') == 'BLK=1 NET=1', 'unexpected build features')
    return values


def native_trace(text: str, config: dict[str, Any], uid: int, gid: int) -> int:
    require('retained until process exit' not in text, 'native lifecycle timed out or failed; see VMM log')
    events = [dict(re.findall(r'\[([a-z_]+)=([^\]]*)\]', line))
              for line in text.splitlines() if line.startswith('helper lifecycle ')]
    expected = ['helper start', 'libkrun loaded', 'context created', 'native vmnet interface ready',
                'helper privileges dropped', 'basic VM configuration complete',
                'device configuration complete', 'krun_start_enter start']
    positions: list[int] = []
    selected: dict[str, dict[str, str]] = {}
    for event in expected:
        matches = [(index, item) for index, item in enumerate(events) if item.get('event') == event]
        require(len(matches) == 1, f'expected exactly one {event!r} event, got {len(matches)}')
        positions.append(matches[0][0])
        selected[event] = matches[0][1]
    require(positions == sorted(positions), 'privileged setup/drop/guest-start ordering is incorrect')
    start = selected['helper start']
    require(start.get('uid') == '0' and start.get('euid') == '0', 'native setup did not start as root')
    require(selected['libkrun loaded'].get('path') == str(LIBRARY), 'VMM loaded an unexpected library')
    require(selected['context created'].get('default_firmware') == 'disabled', 'default firmware lookup was not disabled')
    interfaces = config.get('networks', [])
    require(isinstance(interfaces, list) and len(interfaces) == 1, 'this validation requires exactly one NIC')
    interface = interfaces[0]
    require('socketPath' not in interface and interface.get('features') == 0 and interface.get('flags') == 0,
            'helper configuration uses a packet socket, offloads, or DHCP')
    ready = selected['native vmnet interface ready']
    for key, value in {'api': 'krun_add_net_vmnet_shared', 'backend': 'libkrun-vmnet-shared',
                       'network_index': '0', 'features': '0', 'flags': '0', 'dhcp': 'false', 'isolated': 'true',
                       'gateway': interface['ipv4Gateway'], 'netmask': interface['ipv4Mask']}.items():
        require(ready.get(key) == value, f'native backend attestation mismatch: {key}')
    dropped = selected['helper privileges dropped']
    for key, value in {'uid': str(uid), 'euid': str(uid), 'gid': str(gid), 'egid': str(gid),
                       'root_regain_blocked': 'true'}.items():
        require(dropped.get(key) == value, f'privilege-drop attestation mismatch: {key}')
    pid = int(dropped['pid'])
    require(pid > 1 and start.get('pid') == str(pid), 'helper PID changed or is invalid')
    return pid


def vmm_stop_evidence(text: str) -> None:
    events = [dict(re.findall(r'\[([a-z_]+)=([^\]]*)\]', line))
              for line in text.splitlines() if line.startswith('helper lifecycle ')]
    matches = [event for event in events if event.get('event') == 'VMM stop requested']
    require(matches, 'VMM stop request was not observed')
    require(all(event.get('result') == '0' for event in matches), 'libkrun rejected VMM stop request')
    require('Vmm is stopping.' in text, 'libkrun VMM stop path did not run')


def network_attachment(inspect: Any, config: dict[str, Any]) -> tuple[str, str, str, int | None]:
    require(isinstance(inspect, list) and len(inspect) == 1, 'expected one inspected container')
    networks = inspect[0].get('status', {}).get('networks', [])
    require(len(networks) == 1, 'expected one Apple-assigned live network attachment')
    attachment = networks[0]
    require(attachment.get('variant') == 'allocationOnly', 'network is not allocationOnly')
    address = ipaddress.IPv4Interface(attachment['ipv4Address'])
    gateway = str(ipaddress.IPv4Address(attachment['ipv4Gateway']))
    interface = config['networks'][0]
    require(gateway == interface['ipv4Gateway'] and str(address.netmask) == interface['ipv4Mask'],
            'native subnet differs from Apple allocation')
    require(ipaddress.IPv4Address(gateway) in address.network, 'gateway is outside allocated subnet')
    mac = ':'.join(f'{byte:02x}' for byte in interface['macAddress'])
    require(mac == str(attachment['macAddress']).lower(), 'native MAC differs from Apple allocation')
    return str(address), gateway, mac, attachment.get('mtu')


def assert_counters(before: Any, after: Any, container_id: str) -> None:
    for value in (before, after):
        require(isinstance(value, list) and len(value) == 1 and value[0].get('id') == container_id,
                'stats did not describe the test container')
        for key in ('networkRxBytes', 'networkTxBytes'):
            require(type(value[0].get(key)) is int and value[0][key] >= 0, f'missing/invalid {key}')
    for key in ('networkRxBytes', 'networkTxBytes'):
        require(after[0][key] > before[0][key], f'{key} did not increase')


def processes(text: str) -> dict[int, tuple[int, int, str]]:
    result: dict[int, tuple[int, int, str]] = {}
    for line in text.splitlines():
        fields = line.split(None, 4)
        require(len(fields) == 5, f'unrecognized ps row: {line!r}')
        pid, _ppid, uid, gid = map(int, fields[:4])
        result[pid] = (uid, gid, fields[4])
    return result


def external_helpers(snapshot: dict[int, tuple[int, int, str]]) -> set[int]:
    return {pid for pid, (_, _, command) in snapshot.items()
            if re.search(r'(?:^|/|\s)vmnet-helper(?:\s|$)', command)}


def guest_keepalive_command() -> list[str]:
    return ['sh', '-c', 'while :; do sleep 3600; done']


def guest_http_command(token: str) -> list[str]:
    return [
        'sh', '-ec',
        'if ! command -v httpd >/dev/null 2>&1; then apk add --no-cache busybox-extras; fi; '
        'mkdir -p /www; printf %s "$1" >/www/index.html; httpd -p 8080 -h /www',
        'native-vmnet-http', token,
    ]


def managed_process_exit_status(text: str) -> int | None:
    matches = re.findall(r'\bstatus:\s+(\d+)\s+managed process exit\b', text)
    return int(matches[-1]) if matches else None


@dataclass(frozen=True)
class Result:
    code: int
    output: str
    timed_out: bool = False


def run_command(argv: list[str], path: Path, timeout: float) -> Result:
    """Bound the child and its process group; never block on descendant-held pipes."""
    timed_out = False
    with path.open('wb') as output:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            timed_out = True
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            # Kill the group even if the leader exited but left descendants.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            code = 124
    text = path.read_text(errors='replace')
    path.with_suffix('.command.json').write_text(json.dumps(
        {'argv': argv, 'timeout_seconds': timeout, 'exit_code': code, 'timed_out': timed_out}, indent=2) + '\n')
    return Result(code, text, timed_out)


class Run:
    def __init__(self, directory: Path, timeout: float) -> None:
        self.directory = directory
        self.timeout = timeout
        self.results: list[str] = []

    def record(self, name: str, ok: bool, detail: str = '') -> None:
        text = f'{"PASS" if ok else "FAIL"}: {name}' + (f': {detail}' if detail else '')
        print(text, flush=True)
        self.results.append(text)
        (self.directory / 'results.txt').write_text('\n'.join(self.results) + '\n')

    def command(self, name: str, argv: list[str], *, timeout: float | None = None,
                required: bool = True) -> str:
        print(f'RUN: {name}', flush=True)
        result = run_command(argv, self.directory / f'{name}.txt', timeout or self.timeout)
        if required:
            self.record(name, result.code == 0, '' if result.code == 0 else f'exit={result.code}; see {name}.txt')
            require(result.code == 0, f'{name} failed')
        return result.output

    def copy_bundle(self, bundle: Path) -> None:
        for path in bundle.glob('krun*'):
            if path.is_file() and not path.is_symlink() and path.suffix in ('.log', '.json'):
                shutil.copyfile(path, self.directory / path.name)
        boot = bundle / 'boot.log'
        if boot.is_file():
            shutil.copyfile(boot, self.directory / 'boot.log')


@contextmanager
def host_server(address: str, token: str) -> Iterator[int]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != '/' + token:
                self.send_error(404)
                return
            data = token.encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format: str, *args: Any) -> None:
            pass

    server = ThreadingHTTPServer((address, 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.1}, daemon=True)
    thread.start()
    try:
        yield server.server_port
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def validate_install(run: Run, install_root: Path) -> None:
    plugin = install_root / 'libexec/container-plugins/container-runtime-krun'
    values = provenance((TRUSTED / 'lib/libkrun.provenance').read_text())
    (run.directory / 'libkrun.provenance').write_text((TRUSTED / 'lib/libkrun.provenance').read_text())
    for image, key in ((LIBRARY, 'sha256'), (HELPER, 'helper_sha256'),
                       (plugin / 'lib/libkrun.dylib', 'sha256'),
                       (plugin / 'bin/container-runtime-krun', 'runtime_sha256')):
        require(digest(image) == values[key], f'installed hash does not match provenance: {image}')
    for label, image in (('helper', HELPER), ('libkrun', LIBRARY)):
        check_privileged_path(image)
        commands = run.command(f'{label}-load-commands', ['/usr/bin/otool', '-l', str(image)])
        libraries, rpaths = parse_load_commands(commands)
        require(not rpaths and all(map(trusted_system_library, libraries)), f'unsafe {label} loader dependencies')
        run.command(f'{label}-signature', ['/usr/bin/codesign', '--verify', '--strict', str(image)])
    symbols = run.command('libkrun-symbols', ['/usr/bin/nm', '-gU', str(LIBRARY)])
    for symbol in ('krun_add_net_vmnet_shared', 'krun_create_ctx2', 'krun_request_vmm_stop'):
        require(re.search(rf'\b_{symbol}$', symbols, re.M) is not None, f'missing native ABI: {symbol}')
    run.record('native installation provenance and trusted code', True)


def execute(args: argparse.Namespace, run: Run, container_id: str) -> None:
    require(platform.system() == 'Darwin' and int(platform.mac_ver()[0].split('.')[0]) >= 26,
            'native vmnet validation requires macOS 26 or newer')
    require(os.getuid() != 0, 'run validation as the Apple Container user, not root')
    system = json.loads(run.command('system-status', ['container', 'system', 'status', '--format', 'json']))
    run.command('container-version', ['container', '--version'])
    paths = system['paths']
    install_root = Path(os.environ.get('INSTALL_ROOT') or paths['installRoot'])
    bundle = Path(paths['appRoot']) / 'containers' / container_id
    (run.directory / 'run.json').write_text(json.dumps({
        'container_id': container_id, 'install_root': str(install_root), 'bundle': str(bundle),
        'network': args.network, 'image': args.image, 'outbound_ip': args.outbound_ip,
        'dns_name': args.dns_name, 'outbound_url': args.outbound_url,
        'uid': os.getuid(), 'gid': os.getgid(), 'libkrun_source': str(MANAGED_LIBKRUN),
    }, indent=2) + '\n')
    validate_install(run, install_root)
    run.command('runtime-head', ['git', 'rev-parse', 'HEAD'])
    run.command('runtime-status', ['git', 'status', '--short'])
    if (MANAGED_LIBKRUN / '.git').is_dir():
        run.command('local-libkrun-head', ['git', '-C', str(MANAGED_LIBKRUN), 'rev-parse', 'HEAD'])
        run.command('local-libkrun-status', ['git', '-C', str(MANAGED_LIBKRUN), 'status', '--short'])
    ps_command = ['/bin/ps', '-axo', 'pid=,ppid=,uid=,gid=,command=']
    baseline = processes(run.command('processes-before', ps_command))
    baseline_helpers = external_helpers(baseline)
    baseline_dirs = set(Path('/tmp').glob('container-krun-net-*'))
    snapshots: list[dict[str, Any]] = []
    observer_errors: list[str] = []
    stop_observer = threading.Event()

    def observe() -> None:
        while not stop_observer.is_set():
            try:
                output = subprocess.run(ps_command, capture_output=True, text=True, check=True, timeout=2).stdout
                current = processes(output)
                snapshots.append({'monotonic': time.monotonic(),
                                  'new_external_helpers': sorted(external_helpers(current) - baseline_helpers),
                                  'new_socket_directories': sorted(str(p) for p in set(Path('/tmp').glob('container-krun-net-*')) - baseline_dirs)})
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                observer_errors.append(str(error))
            stop_observer.wait(0.1)

    observer = threading.Thread(target=observe, daemon=True)
    observer.start()
    created = False
    helper_pid: int | None = None
    try:
        token = secrets.token_hex(16)
        created = True  # A timed-out/failed run can still have allocated a container.
        run.command('container-run', ['container', 'run', '-d', '--name', container_id,
                    '--runtime', 'container-runtime-krun', '--network', args.network,
                    args.image, *guest_keepalive_command()], timeout=args.boot_timeout)
        run.copy_bundle(bundle)
        config = json.loads((bundle / 'krun-vmm.json').read_text())
        vmm_log = (bundle / 'krun-vmm.log').read_text()
        helper_pid = native_trace(vmm_log, config, os.getuid(), os.getgid())
        current = processes(run.command('processes-live', ps_command))
        if helper_pid not in current:
            run.command('container-inspect-after-helper-exit', ['container', 'inspect', container_id], required=False)
            run.command('container-logs-after-helper-exit', ['container', 'logs', container_id], required=False)
            guest_status = managed_process_exit_status(vmm_log)
            detail = f'; guest init exited {guest_status}' if guest_status is not None else ''
            raise RuntimeError(f'native helper exited before validation{detail}')
        uid, gid, command = current[helper_pid]
        require((uid, gid) == (os.getuid(), os.getgid()), 'live VMM still has the wrong UID/GID')
        require(str(HELPER) in command and str(bundle / 'krun-vmm.json') in command, 'attested PID is not the test VMM')
        require(not external_helpers(current) - baseline_helpers, 'external vmnet-helper appeared')
        run.record('native entry point, permanent privilege drop, and live VMM identity', True)
        inspected = json.loads(run.command('container-inspect', ['container', 'inspect', container_id]))
        cidr, gateway, mac, mtu = network_attachment(inspected, config)
        before = json.loads(run.command('stats-before', ['container', 'stats', '--no-stream', '--format', 'json', container_id]))
        exec_prefix = ['container', 'exec', container_id]
        addresses = run.command('guest-address', exec_prefix + ['ip', '-o', '-4', 'addr', 'show', 'dev', 'eth0'])
        require(cidr in addresses.split(), 'guest address differs from Apple allocation')
        link = run.command('guest-link', exec_prefix + ['ip', '-o', 'link', 'show', 'dev', 'eth0'])
        require(mac in link.lower().split(), 'guest MAC differs from Apple allocation')
        if mtu is not None:
            require(f'mtu {mtu}' in link, 'guest MTU differs from Apple allocation')
        routes = run.command('guest-routes', exec_prefix + ['ip', '-4', 'route'])
        require(re.search(rf'^default via {re.escape(gateway)} dev eth0(?:\s|$)', routes, re.M) is not None,
                'guest default route differs from Apple allocation')
        run.record('Apple-assigned address, MAC, MTU and default route', True)
        run.command('guest-gateway', exec_prefix + ['ping', '-c', '2', '-W', '2', gateway])
        run.command('guest-outbound-ip', exec_prefix + ['ping', '-c', '2', '-W', '2', args.outbound_ip])
        resolver = run.command('guest-resolver', exec_prefix + ['cat', '/etc/resolv.conf'])
        require(re.search(r'^nameserver\s+\S+', resolver, re.M) is not None, 'guest resolver has no nameserver')
        run.command('guest-dns', exec_prefix + ['nslookup', args.dns_name])
        run.command('guest-outbound-http', exec_prefix + ['wget', '-T', '10', '-qO-', args.outbound_url])
        guest_ip = str(ipaddress.IPv4Interface(cidr).ip)
        run.command('guest-http-server', exec_prefix + guest_http_command(token))
        # Do not let a host HTTP proxy turn this into a false positive.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        deadline = time.monotonic() + 10
        last_error: Exception | None = None
        data = b''
        while time.monotonic() < deadline:
            try:
                with opener.open(f'http://{guest_ip}:8080/', timeout=1) as response:
                    data = response.read(1024)
                break
            except OSError as error:
                last_error = error
                time.sleep(0.1)
        (run.directory / 'host-to-guest.txt').write_bytes(data)
        require(data == token.encode(), f'host did not receive the test guest HTTP token: {last_error}')
        run.record('host-to-guest TCP', True)
        # Bind only the allocated host gateway, and serve no host files.
        with host_server(gateway, token) as port:
            response = run.command('guest-to-host', exec_prefix + ['wget', '-T', '10', '-qO-', f'http://{gateway}:{port}/{token}'])
            require(response == token, 'guest did not receive the test host HTTP token')
        run.record('guest-to-host TCP', True)
        after = json.loads(run.command('stats-after', ['container', 'stats', '--no-stream', '--format', 'json', container_id]))
        assert_counters(before, after, container_id)
        run.record('native network Rx/Tx counters increased', True)
    finally:
        # Cleanup errors are additional evidence, not replacements for the original failure.
        try:
            try:
                run.copy_bundle(bundle)
            except OSError as error:
                run.record('capture live bundle', False, str(error))
            if created:
                for name, argv in [('container-stop', ['container', 'stop', '--time', '5', container_id]),
                                   ('container-delete', ['container', 'delete', container_id])]:
                    try:
                        result = run_command(argv, run.directory / f'{name}.txt', 20)
                        run.record(name, result.code == 0, '' if result.code == 0 else f'exit={result.code}')
                    except Exception as error:
                        run.record(name, False, str(error))
                    if name == 'container-stop':
                        try:
                            run.copy_bundle(bundle)
                        except OSError as error:
                            run.record('capture stopped bundle', False, str(error))
                if helper_pid is not None:
                    deadline = time.monotonic() + 10
                    alive = True
                    while time.monotonic() < deadline:
                        result = subprocess.run(ps_command, check=True, capture_output=True, text=True, timeout=2)
                        alive = helper_pid in processes(result.stdout)
                        if not alive:
                            break
                        time.sleep(0.1)
                    run.record('native VMM exited after stop/delete', not alive)
        except Exception as error:
            run.record('cleanup', False, str(error))
        finally:
            stop_observer.set()
            observer.join(timeout=3)
            if observer.is_alive():
                observer_errors.append('process observer did not exit')
            (run.directory / 'backend-observations.json').write_text(json.dumps(
                {'samples': snapshots, 'errors': observer_errors}, indent=2) + '\n')
            run.record('no sampled external packet helper or socket fallback', bool(snapshots) and not observer_errors
                       and all(not s['new_external_helpers'] and not s['new_socket_directories'] for s in snapshots))
            log = run.directory / 'krun-vmm.log'
            if log.exists():
                log_text = log.read_text()
                try:
                    vmm_stop_evidence(log_text)
                    run.record('native VMM stop reached exit observers', True)
                except Exception as error:
                    run.record('native VMM stop reached exit observers', False, str(error))
                run.record('no native timeout/quarantined teardown reported', 'retained until process exit' not in log_text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--network', default='default')
    parser.add_argument('--image', default='alpine:3.20', help='image must include sh, sleep, apk, ip, ping, nslookup, and wget (default: Alpine)')
    parser.add_argument('--output', type=Path, default=Path('validation-results'))
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--boot-timeout', type=float, default=90)
    parser.add_argument('--outbound-ip', default='1.1.1.1')
    parser.add_argument('--dns-name', default='example.com')
    parser.add_argument('--outbound-url', default='http://example.com/')
    args = parser.parse_args()
    require(args.timeout > 0 and args.boot_timeout > 0, 'timeouts must be positive')
    ipaddress.IPv4Address(args.outbound_ip)
    require(args.outbound_url.startswith(('http://', 'https://')), 'outbound URL must use HTTP(S)')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    container_id = f'krun-native-{stamp}-{os.getpid()}'
    directory = args.output.resolve() / container_id
    directory.mkdir(parents=True, exist_ok=False)
    run = Run(directory, args.timeout)
    try:
        execute(args, run, container_id)
    except (Exception, KeyboardInterrupt) as error:
        run.record('native validation', False, f'{type(error).__name__}: {error}')
    failed = any(line.startswith('FAIL:') for line in run.results)
    (directory / 'SUMMARY.json').write_text(json.dumps({'success': not failed, 'container_id': container_id,
                                                       'scope': 'one native NIC; no runtime installation performed',
                                                       'results': run.results}, indent=2) + '\n')
    archive = directory.with_suffix('.tar.gz')
    with tarfile.open(archive, 'w:gz') as output:
        output.add(directory, arcname=directory.name)
    print(f'archive: {archive}', flush=True)
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
