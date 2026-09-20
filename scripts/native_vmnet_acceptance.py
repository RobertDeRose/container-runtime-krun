#!/usr/bin/env python3
"""Validate native-vmnet concurrency, multi-NIC, publications, failure cleanup, and final regression gates."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import subprocess
import tarfile
import threading
import time
from typing import Any, Iterator
import urllib.request

import native_vmnet_validation as native

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNTIME = 'container-runtime-krun'


@dataclass
class ContainerEvidence:
    container_id: str
    bundle: Path
    config: dict[str, Any]
    helper_pid: int
    inspect: list[dict[str, Any]]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def lifecycle_events(text: str) -> list[dict[str, str]]:
    return [dict(re.findall(r'\[([a-z_]+)=([^\]]*)\]', line))
            for line in text.splitlines() if line.startswith('helper lifecycle ')]


def native_trace_many(text: str, config: dict[str, Any], uid: int, gid: int) -> int:
    networks = config.get('networks')
    require(isinstance(networks, list) and networks, 'native validation requires at least one NIC')
    if len(networks) == 1:
        return native.native_trace(text, config, uid, gid)

    require('retained until process exit' not in text, 'native lifecycle timed out or retained resources')
    events = lifecycle_events(text)
    names = [event.get('event') for event in events]
    for name in ('helper start', 'libkrun loaded', 'context created', 'helper privileges dropped',
                 'basic VM configuration complete', 'device configuration complete', 'krun_start_enter start'):
        require(names.count(name) == 1, f'expected exactly one {name!r} event')
    ready = [event for event in events if event.get('event') == 'native vmnet interface ready']
    require(len(ready) == len(networks),
            f'expected {len(networks)} native interface-ready events, found {len(ready)}')
    by_index: dict[int, dict[str, str]] = {}
    for event in ready:
        index = int(event.get('network_index', '-1'))
        require(index not in by_index, f'duplicate native network index {index}')
        by_index[index] = event
    require(sorted(by_index) == list(range(len(networks))), 'native network indices are incomplete')

    start_index = names.index('helper start')
    load_index = names.index('libkrun loaded')
    context_index = names.index('context created')
    drop_index = names.index('helper privileges dropped')
    basic_index = names.index('basic VM configuration complete')
    device_index = names.index('device configuration complete')
    enter_index = names.index('krun_start_enter start')
    ready_indices = [events.index(by_index[index]) for index in range(len(networks))]
    require(
        start_index < load_index < context_index < min(ready_indices),
        'native setup ordering before NICs is incorrect',
    )
    require(max(ready_indices) < drop_index < basic_index < device_index < enter_index,
            'native NIC/drop/guest-start ordering is incorrect')

    start = events[start_index]
    require(start.get('uid') == '0' and start.get('euid') == '0', 'native setup did not start as root')
    loaded = events[load_index]
    require(loaded.get('path') == str(native.LIBRARY), 'VMM loaded unexpected libkrun')
    require(events[context_index].get('default_firmware') == 'disabled', 'default firmware lookup was not disabled')
    dropped = events[drop_index]
    for key, value in {'uid': str(uid), 'euid': str(uid), 'gid': str(gid), 'egid': str(gid),
                       'root_regain_blocked': 'true'}.items():
        require(dropped.get(key) == value, f'privilege-drop attestation mismatch: {key}')
    pid = int(dropped['pid'])
    require(pid > 1 and start.get('pid') == str(pid), 'helper PID changed or is invalid')

    for index, interface in enumerate(networks):
        require('socketPath' not in interface and interface.get('features') == 0 and interface.get('flags') == 0,
                f'network {index} uses legacy socket/offload/DHCP configuration')
        event = by_index[index]
        expected = {
            'api': 'krun_add_net_vmnet_shared',
            'backend': 'libkrun-vmnet-shared',
            'network_index': str(index),
            'features': '0',
            'flags': '0',
            'vmnet_api': 'vmnet_start_interface',
            'guest_dhcp': 'false',
            'isolated': 'true',
            'gateway': interface['ipv4Gateway'],
            'netmask': interface['ipv4Mask'],
        }
        for key, value in expected.items():
            require(event.get(key) == value, f'native network {index} attestation mismatch: {key}')
    return pid


def container_attachments(inspect: Any) -> list[dict[str, Any]]:
    require(isinstance(inspect, list) and len(inspect) == 1, 'expected one inspected container')
    attachments = inspect[0].get('status', {}).get('networks', [])
    require(isinstance(attachments, list) and attachments, 'container has no live network attachments')
    return attachments


def has_connected_route(routes: str, network: ipaddress.IPv4Network, device: str) -> bool:
    expected = str(network)
    for line in routes.splitlines():
        fields = line.split()
        if not fields or fields[0] != expected:
            continue
        try:
            dev_index = fields.index('dev')
        except ValueError:
            continue
        if dev_index + 1 < len(fields) and fields[dev_index + 1] == device:
            return True
    return False


def wait_for_exec(container_id: str, timeout: float = 20) -> None:
    deadline = time.monotonic() + timeout
    last = ''
    while time.monotonic() < deadline:
        result = subprocess.run(['container', 'exec', container_id, 'true'], capture_output=True, text=True, timeout=3)
        if result.returncode == 0:
            return
        last = result.stdout + result.stderr
        time.sleep(0.2)
    raise RuntimeError(f'{container_id} did not become exec-ready: {last[-500:]}')


def wait_pid_gone(pid: int, timeout: float = 10) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'pid='], capture_output=True, text=True, timeout=2)
        if result.returncode != 0 or not result.stdout.strip():
            return True
        time.sleep(0.1)
    return False


def http_get(address: str, port: int, expected: str, timeout: float = 10) -> None:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with opener.open(f'http://{address}:{port}/', timeout=1) as response:
                data = response.read(4096).decode()
            require(data == expected, f'unexpected HTTP body from {address}:{port}: {data!r}')
            return
        except (OSError, RuntimeError) as error:
            last = error
            time.sleep(0.1)
    raise RuntimeError(f'HTTP probe to {address}:{port} failed: {last}')


def free_port(kind: int) -> int:
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return int(sock.getsockname()[1])


def recv_exact(sock: Any, length: int) -> bytes:
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def tcp_echo_address(address: str, port: int, payload: bytes, *, timeout: float = 20,
                     description: str = 'TCP echo') -> None:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((address, port), timeout=1) as sock:
                sock.settimeout(1)
                sock.sendall(payload)
                received = recv_exact(sock, len(payload))
            require(received == payload, f'unexpected {description} payload: {received!r}')
            return
        except (OSError, RuntimeError) as error:
            last = error
            time.sleep(0.1)
    raise RuntimeError(f'{description} failed: {last}')


def tcp_echo(port: int, payload: bytes, timeout: float = 20) -> None:
    tcp_echo_address('127.0.0.1', port, payload, timeout=timeout, description='TCP publication')


def udp_echo_address(address: str, port: int, payload: bytes, *, timeout: float = 20,
                     description: str = 'UDP echo') -> None:
    deadline = time.monotonic() + timeout
    last: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(1)
                sock.sendto(payload, (address, port))
                received, _ = sock.recvfrom(65535)
            require(received == payload, f'unexpected {description} payload: {received!r}')
            return
        except (OSError, RuntimeError) as error:
            last = error
            time.sleep(0.1)
    raise RuntimeError(f'{description} failed: {last}')


def udp_echo(port: int, payload: bytes, timeout: float = 20) -> None:
    udp_echo_address('127.0.0.1', port, payload, timeout=timeout, description='UDP publication')


def bindable(kind: int, port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, kind) as sock:
            if kind == socket.SOCK_STREAM:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', port))
        return True
    except OSError:
        return False


@contextmanager
def reserve_tcp_port() -> Iterator[int]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    sock.listen(1)
    try:
        yield int(sock.getsockname()[1])
    finally:
        sock.close()


def legacy_source_violations(root: Path = PROJECT_ROOT) -> list[str]:
    roots = [root / 'Sources', root / 'plugin']
    files = [root / 'mise.toml', root / 'scripts/install_native_vmnet.sh', root / 'scripts/build_native_libkrun.sh']
    for directory in roots:
        if directory.exists():
            files.extend(path for path in directory.rglob('*') if path.is_file())
    forbidden = ('vmnet-helper', 'krun_add_net_unixgram', 'container-krun-net-')
    violations: list[str] = []
    for path in sorted(set(files)):
        try:
            text = path.read_text(errors='replace')
        except OSError:
            continue
        for token in forbidden:
            if token in text:
                violations.append(f'{path.relative_to(root)}: {token}')
    return violations


def copy_bundle_named(run: native.Run, bundle: Path, prefix: str) -> None:
    for path in bundle.glob('krun*'):
        if path.is_file() and not path.is_symlink() and path.suffix in ('.log', '.json'):
            target = run.directory / f'{prefix}-{path.name}'
            target.write_bytes(path.read_bytes())
    boot = bundle / 'boot.log'
    if boot.is_file():
        (run.directory / f'{prefix}-boot.log').write_bytes(boot.read_bytes())


class Acceptance:
    def __init__(self, args: argparse.Namespace, run: native.Run, system: dict[str, Any], prefix: str) -> None:
        self.args = args
        self.run = run
        self.system = system
        self.prefix = prefix
        self.app_root = Path(system['paths']['appRoot'])
        self.created_containers: set[str] = set()
        self.created_networks: set[str] = set()
        self.baseline_processes = native.processes(run.command(
            'processes-before', ['/bin/ps', '-axo', 'pid=,ppid=,uid=,gid=,command=']))
        self.baseline_helpers = native.external_helpers(self.baseline_processes)
        self.baseline_dirs = set(Path('/tmp').glob('container-krun-net-*'))
        self.snapshots: list[dict[str, Any]] = []
        self.observer_errors: list[str] = []
        self.stop_observer = threading.Event()
        self.observer = threading.Thread(target=self._observe, daemon=True)
        self.observer.start()

    def _observe(self) -> None:
        argv = ['/bin/ps', '-axo', 'pid=,ppid=,uid=,gid=,command=']
        while not self.stop_observer.is_set():
            try:
                output = subprocess.run(argv, check=True, capture_output=True, text=True, timeout=2).stdout
                current = native.processes(output)
                self.snapshots.append({
                    'monotonic': time.monotonic(),
                    'new_external_helpers': sorted(native.external_helpers(current) - self.baseline_helpers),
                    'new_socket_directories': sorted(str(path) for path in
                        set(Path('/tmp').glob('container-krun-net-*')) - self.baseline_dirs),
                })
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                self.observer_errors.append(str(error))
            self.stop_observer.wait(0.1)

    def bundle(self, container_id: str) -> Path:
        return self.app_root / 'containers' / container_id

    def start(self, suffix: str, networks: list[str], *, publishes: list[str] | None = None,
              command: list[str] | None = None) -> ContainerEvidence:
        container_id = f'{self.prefix}-{suffix}'
        argv = ['container', 'run', '-d', '--name', container_id, '--runtime', RUNTIME]
        for network in networks:
            argv += ['--network', network]
        for publish in publishes or []:
            argv += ['--publish', publish]
        argv += [self.args.image, *(command or native.guest_keepalive_command())]
        self.created_containers.add(container_id)
        self.run.command(f'{suffix}-run', argv, timeout=self.args.boot_timeout)
        wait_for_exec(container_id)
        bundle = self.bundle(container_id)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not (bundle / 'krun-vmm.log').is_file():
            time.sleep(0.1)
        require((bundle / 'krun-vmm.log').is_file() and (bundle / 'krun-vmm.json').is_file(),
                f'{container_id} VMM evidence did not appear')
        copy_bundle_named(self.run, bundle, suffix)
        config = json.loads((bundle / 'krun-vmm.json').read_text())
        text = (bundle / 'krun-vmm.log').read_text()
        helper_pid = native_trace_many(text, config, os.getuid(), os.getgid())
        current = native.processes(self.run.command(
            f'{suffix}-processes-live', ['/bin/ps', '-axo', 'pid=,ppid=,uid=,gid=,command=']))
        require(helper_pid in current, f'{container_id} VMM helper is not live')
        uid, gid, process_command = current[helper_pid]
        require((uid, gid) == (os.getuid(), os.getgid()), f'{container_id} VMM did not drop privileges')
        require(str(native.HELPER) in process_command, f'{container_id} attested PID is not protected helper')
        require(not native.external_helpers(current) - self.baseline_helpers, 'external vmnet-helper appeared')
        inspected = json.loads(self.run.command(f'{suffix}-inspect', ['container', 'inspect', container_id]))
        return ContainerEvidence(container_id, bundle, config, helper_pid, inspected)

    def stop_delete(self, evidence: ContainerEvidence, suffix: str) -> None:
        self.run.command(f'{suffix}-stop', ['container', 'stop', '--time', '5', evidence.container_id], timeout=20)
        copy_bundle_named(self.run, evidence.bundle, f'{suffix}-stopped')
        log = (evidence.bundle / 'krun-vmm.log').read_text()
        native.vmm_stop_evidence(log)
        require(
            'retained until process exit' not in log,
            f'{evidence.container_id} reported quarantined native resources',
        )
        self.run.command(f'{suffix}-delete', ['container', 'delete', evidence.container_id], timeout=20)
        require(wait_pid_gone(evidence.helper_pid), f'{evidence.container_id} VMM helper remained after delete')
        self.created_containers.discard(evidence.container_id)

    def force_delete(self, container_id: str, suffix: str) -> None:
        result = native.run_command(['container', 'delete', '--force', container_id],
                                    self.run.directory / f'{suffix}-force-delete.txt', 20)
        if result.code != 0:
            inspect = native.run_command(['container', 'inspect', container_id],
                                         self.run.directory / f'{suffix}-after-force-delete-inspect.txt', 5)
            require(inspect.code != 0, f'{container_id} still exists after force delete failure')
        self.created_containers.discard(container_id)

    def create_network(self, suffix: str, subnet: str, variant: str = 'allocationOnly') -> str:
        name = f'knv-{self.prefix.rsplit("-", 1)[-1]}-{suffix}'
        self.run.command(f'network-{suffix}-create',
                         ['container', 'network', 'create', '--subnet', subnet, '--option', f'variant={variant}', name])
        self.created_networks.add(name)
        return name

    def delete_network(self, name: str, suffix: str) -> None:
        self.run.command(f'network-{suffix}-delete', ['container', 'network', 'delete', name])
        self.created_networks.discard(name)

    def close(self) -> None:
        for container_id in list(self.created_containers):
            native.run_command(['container', 'delete', '--force', container_id],
                               self.run.directory / f'cleanup-{container_id}.txt', 20)
        for network in list(self.created_networks):
            native.run_command(['container', 'network', 'delete', network],
                               self.run.directory / f'cleanup-network-{network}.txt', 20)
        self.stop_observer.set()
        self.observer.join(timeout=3)
        if self.observer.is_alive():
            self.observer_errors.append('process observer did not exit')
        (self.run.directory / 'backend-observations.json').write_text(json.dumps(
            {'samples': self.snapshots, 'errors': self.observer_errors}, indent=2) + '\n')
        clean = (bool(self.snapshots) and not self.observer_errors and
                 all(not sample['new_external_helpers'] and not sample['new_socket_directories']
                     for sample in self.snapshots))
        self.run.record('no external packet helper or legacy socket fallback during acceptance', clean)


def stats(run: native.Run, label: str, container_id: str) -> Any:
    return json.loads(run.command(label, ['container', 'stats', '--no-stream', '--format', 'json', container_id]))


def start_http(run: native.Run, label: str, container_id: str, token: str) -> None:
    run.command(label, ['container', 'exec', container_id, *native.guest_http_command(token)])


def validate_bidirectional(run: native.Run, evidence: ContainerEvidence, suffix: str, token: str) -> None:
    attachments = container_attachments(evidence.inspect)
    require(len(attachments) == 1, f'{evidence.container_id} expected one attachment')
    address = str(ipaddress.IPv4Interface(attachments[0]['ipv4Address']).ip)
    gateway = str(ipaddress.IPv4Address(attachments[0]['ipv4Gateway']))
    before = stats(run, f'{suffix}-stats-before', evidence.container_id)
    start_http(run, f'{suffix}-http-server', evidence.container_id, token)
    http_get(address, 8080, token)
    (run.directory / f'{suffix}-host-to-guest.txt').write_text(f'{address}:8080 {token}\n')
    with native.host_server(gateway, token) as port:
        response = run.command(f'{suffix}-guest-to-host',
                               ['container', 'exec', evidence.container_id, 'wget', '-T', '10', '-qO-',
                                f'http://{gateway}:{port}/{token}'])
        require(response == token, f'{evidence.container_id} guest-to-host token mismatch')
    run.command(f'{suffix}-gateway', ['container', 'exec', evidence.container_id,
                                      'ping', '-c', '1', '-W', '2', gateway])
    after = stats(run, f'{suffix}-stats-after', evidence.container_id)
    native.assert_counters(before, after, evidence.container_id)


def concurrent_phase(acc: Acceptance) -> None:
    run = acc.run
    a = acc.start('concurrent-a', [acc.args.network])
    b = acc.start('concurrent-b', [acc.args.network])
    attachments_a = container_attachments(a.inspect)
    attachments_b = container_attachments(b.inspect)
    ip_a = ipaddress.IPv4Interface(attachments_a[0]['ipv4Address']).ip
    ip_b = ipaddress.IPv4Interface(attachments_b[0]['ipv4Address']).ip
    require(ip_a != ip_b, 'concurrent VMs received the same Apple address')
    require(attachments_a[0]['ipv4Gateway'] == attachments_b[0]['ipv4Gateway'],
            'concurrent VMs did not use the same Apple network gateway')
    token_a = secrets.token_hex(12)
    token_b = secrets.token_hex(12)
    validate_bidirectional(run, a, 'concurrent-a', token_a)
    validate_bidirectional(run, b, 'concurrent-b', token_b)
    acc.stop_delete(a, 'concurrent-a')
    run.command('concurrent-b-after-a-stop', ['container', 'exec', b.container_id,
                                              'ping', '-c', '1', '-W', '2', attachments_b[0]['ipv4Gateway']])
    http_get(str(ip_b), 8080, token_b)
    c = acc.start('concurrent-c', [acc.args.network])
    ip_c = ipaddress.IPv4Interface(container_attachments(c.inspect)[0]['ipv4Address']).ip
    require(ip_c != ip_b, 'third VM reused the address of the still-running second VM')
    validate_bidirectional(run, c, 'concurrent-c', secrets.token_hex(12))
    acc.stop_delete(b, 'concurrent-b')
    acc.stop_delete(c, 'concurrent-c')
    run.record('concurrent VMs share one Apple network without lifecycle interference', True)


def multi_nic_phase(acc: Acceptance) -> None:
    run = acc.run
    net_a = acc.create_network('a', acc.args.subnet_a)
    net_b = acc.create_network('b', acc.args.subnet_b)
    evidence = acc.start('multinic', [net_a, net_b])
    attachments = container_attachments(evidence.inspect)
    require(
        len(attachments) == 2 and len(evidence.config['networks']) == 2,
        'multi-NIC container did not get two attachments',
    )
    expected = [ipaddress.IPv4Network(acc.args.subnet_a), ipaddress.IPv4Network(acc.args.subnet_b)]
    addresses: list[ipaddress.IPv4Interface] = []
    for index, network in enumerate(expected):
        address = ipaddress.IPv4Interface(attachments[index]['ipv4Address'])
        require(address.ip in network, f'eth{index} Apple address {address.ip} is outside {network}')
        addresses.append(address)
        guest = run.command(f'multinic-eth{index}', ['container', 'exec', evidence.container_id,
                                                    'ip', '-o', '-4', 'addr', 'show', 'dev', f'eth{index}'])
        require(str(address) in guest.split(), f'eth{index} guest address differs from Apple allocation')
        run.command(f'multinic-gateway-{index}', ['container', 'exec', evidence.container_id,
                                                  'ping', '-c', '1', '-W', '2', attachments[index]['ipv4Gateway']])
    routes = run.command('multinic-routes', ['container', 'exec', evidence.container_id, 'ip', '-4', 'route'])
    require(
        len(re.findall(r'^default\s', routes, re.M)) == 1
        and re.search(r'^default .* dev eth0(?:\s|$)', routes, re.M),
        'multi-NIC default route is not exclusively on eth0',
    )
    require(has_connected_route(routes, expected[1], 'eth1'), 'eth1 connected route is missing')
    token = secrets.token_hex(12)
    start_http(run, 'multinic-http-server', evidence.container_id, token)
    for index, address in enumerate(addresses):
        http_get(str(address.ip), 8080, token)
        (run.directory / f'multinic-host-to-guest-{index}.txt').write_text(f'{address.ip}:8080 {token}\n')
    acc.stop_delete(evidence, 'multinic')

    # Exercise rollback after the first valid attachment has been allocated and the second
    # attachment is rejected as a reserved network.
    bad = acc.create_network('reserved', acc.args.subnet_bad, variant='reserved')
    bad_id = f'{acc.prefix}-multinic-partial'
    acc.created_containers.add(bad_id)
    result = native.run_command(
        ['container', 'run', '-d', '--name', bad_id, '--runtime', RUNTIME,
         '--network', net_a, '--network', bad, acc.args.image, *native.guest_keepalive_command()],
        run.directory / 'multinic-partial-run.txt', acc.args.boot_timeout)
    require(result.code != 0, 'reserved second attachment unexpectedly started')
    run.record('partial multi-network startup rejected', True)
    acc.force_delete(bad_id, 'multinic-partial')
    recovery = acc.start('multinic-recovery', [net_a])
    acc.stop_delete(recovery, 'multinic-recovery')
    acc.delete_network(bad, 'reserved')
    acc.delete_network(net_a, 'a')
    acc.delete_network(net_b, 'b')
    run.record('multiple native NICs and partial-allocation rollback', True)


def capture_port_diagnostics(run: native.Run, evidence: ContainerEvidence) -> None:
    commands = {
        'ports-diagnostic-processes': ['container', 'exec', evidence.container_id, 'ps'],
        'ports-diagnostic-listeners': [
            'container', 'exec', evidence.container_id, 'sh', '-c', 'netstat -lnptu 2>/dev/null || true'
        ],
        'ports-diagnostic-apk-socat': [
            'container', 'exec', evidence.container_id, 'sh', '-c', 'cat /tmp/apk-socat.log 2>/dev/null || true'
        ],
        'ports-diagnostic-system-logs': ['container', 'system', 'logs', '--debug', '--last', '5m'],
    }
    for label, argv in commands.items():
        try:
            native.run_command(argv, run.directory / f'{label}.txt', 20)
        except Exception as error:
            (run.directory / f'{label}-capture-error.txt').write_text(f'{error}\n')

    logs = run.directory / 'ports-diagnostic-system-logs.txt'
    if logs.is_file():
        relevant = [
            line for line in logs.read_text(errors='replace').splitlines()
            if evidence.container_id in line
            or 'port forwarder' in line.lower()
            or 'backend - connect' in line.lower()
            or 'socketforwarder' in line.lower()
        ]
        (run.directory / 'ports-diagnostic-forwarder-logs.txt').write_text('\n'.join(relevant) + ('\n' if relevant else ''))


def port_phase(acc: Acceptance) -> None:
    run = acc.run
    tcp_port = free_port(socket.SOCK_STREAM)
    udp_port = free_port(socket.SOCK_DGRAM)
    guest_script = (
        'set -eu; apk add --no-cache socat >/tmp/apk-socat.log 2>&1; '
        'socat TCP4-LISTEN:8080,reuseaddr,fork EXEC:/bin/cat & '
        'socat UDP4-RECVFROM:8081,reuseaddr,fork EXEC:/bin/cat & '
        'while :; do sleep 3600; done'
    )
    evidence = acc.start('ports', [acc.args.network],
                         publishes=[f'127.0.0.1:{tcp_port}:8080/tcp', f'127.0.0.1:{udp_port}:8081/udp'],
                         command=['sh', '-c', guest_script])
    deadline = time.monotonic() + 45
    listeners = ''
    while time.monotonic() < deadline:
        listeners = subprocess.run(
            ['container', 'exec', evidence.container_id, 'sh', '-c', 'netstat -lnptu 2>/dev/null || true'],
            capture_output=True,
            text=True,
            timeout=3,
        ).stdout
        if re.search(r'[:.]8080\s', listeners) and re.search(r'[:.]8081\s', listeners):
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('guest TCP/UDP listeners did not become ready')
    (run.directory / 'ports-guest-listeners.txt').write_text(listeners)

    address = str(ipaddress.IPv4Interface(container_attachments(evidence.inspect)[0]['ipv4Address']).ip)
    tcp_payload = b'native-published-tcp\n'
    udp_payload = b'native-published-udp'
    try:
        tcp_echo_address(address, 8080, tcp_payload, description='direct guest TCP echo')
        (run.directory / 'ports-direct-tcp.txt').write_text(f'{address}:8080 direct echo passed\n')
        udp_echo_address(address, 8081, udp_payload, description='direct guest UDP echo')
        (run.directory / 'ports-direct-udp.txt').write_text(f'{address}:8081 direct echo passed\n')
        run.record('direct guest TCP and UDP echo services are reachable', True)

        tcp_echo(tcp_port, tcp_payload)
        udp_echo(udp_port, udp_payload)
        run.record('published TCP and UDP ports reach native guest', True)
    except Exception:
        capture_port_diagnostics(run, evidence)
        raise
    acc.stop_delete(evidence, 'ports')
    require(bindable(socket.SOCK_STREAM, tcp_port), 'published TCP port was not released')
    require(bindable(socket.SOCK_DGRAM, udp_port), 'published UDP port was not released')

    # Fail after at least one forwarder can bind and verify rollback/reuse.
    first_port = free_port(socket.SOCK_STREAM)
    with reserve_tcp_port() as occupied:
        fail_id = f'{acc.prefix}-port-partial'
        acc.created_containers.add(fail_id)
        result = native.run_command(
            ['container', 'run', '-d', '--name', fail_id, '--runtime', RUNTIME, '--network', acc.args.network,
             '--publish', f'127.0.0.1:{first_port}:8082/tcp',
             '--publish', f'127.0.0.1:{occupied}:8083/tcp',
             acc.args.image, *native.guest_keepalive_command()],
            run.directory / 'port-partial-run.txt', acc.args.boot_timeout)
        require(result.code != 0, 'occupied host port did not reject bootstrap')
        run.record('partial published-port bootstrap rejected', True)
        acc.force_delete(fail_id, 'port-partial')
    require(bindable(socket.SOCK_STREAM, first_port), 'forwarder opened before failure was not released')
    recovery = acc.start('port-recovery', [acc.args.network])
    acc.stop_delete(recovery, 'port-recovery')
    run.record('published-port rollback leaves native network reusable', True)


def abnormal_phase(acc: Acceptance) -> None:
    run = acc.run
    evidence = acc.start('crash', [acc.args.network])
    os.kill(evidence.helper_pid, signal.SIGKILL)
    require(wait_pid_gone(evidence.helper_pid), 'SIGKILLed VMM helper did not exit')
    run.record('abrupt VMM SIGKILL observed', True)
    acc.force_delete(evidence.container_id, 'crash')
    recovery = acc.start('crash-recovery', [acc.args.network])
    validate_bidirectional(run, recovery, 'crash-recovery', secrets.token_hex(12))
    acc.stop_delete(recovery, 'crash-recovery')
    run.record('native network is reusable after abrupt VMM death', True)


def run_regressions(args: argparse.Namespace, run: native.Run) -> None:
    # Native acceptance replaces the old helper-specific networking/multi-network/port collectors.
    commands = [
        ('runtime-regression', ['scripts/validate_runtime_regression.sh', '--memory-observe-seconds', '0']),
        ('init-regression', ['scripts/validate_init.sh']),
        ('copy-regression', ['scripts/validate_copy.sh']),
        ('volume-regression', ['scripts/validate_volumes.sh']),
        ('unix-socket-regression', ['scripts/validate_unix_sockets.sh']),
        ('virtiofs-regression', ['scripts/validate_virtiofs.sh']),
        ('logs-clean-regression', ['scripts/validate_logs_clean.sh']),
        ('snapshot-regression', ['scripts/validate_snapshot.sh']),
        ('fail-closed-regression', ['scripts/validate_fail_closed.sh']),
    ]
    for name, argv in commands:
        result = native.run_command(argv, run.directory / f'{name}.txt', args.regression_timeout)
        run.record(name, result.code == 0, '' if result.code == 0 else f'exit={result.code}')
        require(result.code == 0, f'{name} failed')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--network', default='default')
    parser.add_argument('--image', default='alpine:3.20')
    parser.add_argument('--subnet-a', default='10.250.40.0/24')
    parser.add_argument('--subnet-b', default='10.250.41.0/24')
    parser.add_argument('--subnet-bad', default='10.250.42.0/24')
    parser.add_argument('--output', type=Path, default=Path('validation-results'))
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--boot-timeout', type=float, default=90)
    parser.add_argument('--regression-timeout', type=float, default=900)
    parser.add_argument(
        '--skip-regression',
        action='store_true',
        help='skip the final non-superseded regression collectors',
    )
    args = parser.parse_args()
    for value in (args.subnet_a, args.subnet_b, args.subnet_bad):
        network = ipaddress.ip_network(value)
        require(network.version == 4, 'acceptance subnets must be IPv4')
    networks = [
        ipaddress.ip_network(args.subnet_a),
        ipaddress.ip_network(args.subnet_b),
        ipaddress.ip_network(args.subnet_bad),
    ]
    require(all(not a.overlaps(b) for index, a in enumerate(networks) for b in networks[index + 1:]),
            'acceptance subnets must not overlap')
    require(args.timeout > 0 and args.boot_timeout > 0 and args.regression_timeout > 0, 'timeouts must be positive')

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    prefix = f'knva-{stamp}-{os.getpid()}'
    directory = args.output.resolve() / f'native-acceptance-{stamp}-{os.getpid()}'
    directory.mkdir(parents=True, exist_ok=False)
    run = native.Run(directory, args.timeout)
    acceptance: Acceptance | None = None
    try:
        require(os.uname().sysname == 'Darwin', 'native vmnet acceptance requires macOS')
        system = json.loads(run.command('system-status', ['container', 'system', 'status', '--format', 'json']))
        install_root = Path(system['paths']['installRoot'])
        native.validate_install(run, install_root)
        violations = legacy_source_violations()
        (directory / 'legacy-source-violations.txt').write_text('\n'.join(violations) + ('\n' if violations else ''))
        require(not violations, f'legacy packet backend remains in production sources: {violations}')
        run.record('legacy external-helper implementation removed from production path', True)

        acceptance = Acceptance(args, run, system, prefix)
        for name, phase in (
            ('concurrent same-network VMs', concurrent_phase),
            ('multiple native NICs and rollback', multi_nic_phase),
            ('published TCP/UDP ports and rollback', port_phase),
            ('abrupt VMM death and recovery', abnormal_phase),
        ):
            print(f'PHASE: {name}', flush=True)
            phase(acceptance)
        if not args.skip_regression:
            print('PHASE: non-superseded full regression collectors', flush=True)
            run_regressions(args, run)
    except (Exception, KeyboardInterrupt) as error:
        run.record('native vmnet acceptance', False, f'{type(error).__name__}: {error}')
    finally:
        if acceptance is not None:
            try:
                acceptance.close()
            except Exception as error:
                run.record('acceptance cleanup', False, str(error))

    failed = any(line.startswith('FAIL:') for line in run.results)
    summary = {
        'success': not failed,
        'scope': (
            'native vmnet steps 2-6: concurrency, multi-NIC, publications, abnormal cleanup, '
            'legacy-removal/regression gate'
        ),
        'results': run.results,
        'regression_skipped': args.skip_regression,
    }
    (directory / 'SUMMARY.json').write_text(json.dumps(summary, indent=2) + '\n')
    archive = directory.with_suffix('.tar.gz')
    with tarfile.open(archive, 'w:gz') as output:
        output.add(directory, arcname=directory.name)
    print(f'archive: {archive}', flush=True)
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
