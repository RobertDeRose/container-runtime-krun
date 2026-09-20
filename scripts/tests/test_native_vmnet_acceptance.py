from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_vmnet_acceptance as acceptance


def config_two() -> dict:
    return {
        'networks': [
            {'ipv4Gateway': '10.250.40.1', 'ipv4Mask': '255.255.255.0',
             'macAddress': [2, 0, 0, 0, 0, 1], 'features': 0, 'flags': 0},
            {'ipv4Gateway': '10.250.41.1', 'ipv4Mask': '255.255.255.0',
             'macAddress': [2, 0, 0, 0, 0, 2], 'features': 0, 'flags': 0},
        ]
    }


def trace_two() -> str:
    return '\n'.join([
        'helper lifecycle [event=helper start] [pid=321] [uid=0] [euid=0]',
        f'helper lifecycle [event=libkrun loaded] [path={acceptance.native.LIBRARY}]',
        'helper lifecycle [event=context created] [default_firmware=disabled]',
        'helper lifecycle [event=native vmnet interface ready] [backend=libkrun-vmnet-shared] '
        '[api=krun_add_net_vmnet_shared] [network_index=0] [features=0] [flags=0] '
        '[gateway=10.250.40.1] [netmask=255.255.255.0] [guest_dhcp=false] [isolated=true] [vmnet_api=vmnet_start_interface]',
        'helper lifecycle [event=native vmnet interface ready] [backend=libkrun-vmnet-shared] '
        '[api=krun_add_net_vmnet_shared] [network_index=1] [features=0] [flags=0] '
        '[gateway=10.250.41.1] [netmask=255.255.255.0] [guest_dhcp=false] [isolated=true] [vmnet_api=vmnet_start_interface]',
        'helper lifecycle [event=helper privileges dropped] [pid=321] [uid=502] [euid=502] '
        '[gid=20] [egid=20] [root_regain_blocked=true]',
        'helper lifecycle [event=basic VM configuration complete]',
        'helper lifecycle [event=device configuration complete]',
        'helper lifecycle [event=krun_start_enter start]',
        '',
    ])


class NativeTraceManyTests(unittest.TestCase):
    def test_two_interfaces_are_attested_before_privilege_drop(self) -> None:
        self.assertEqual(acceptance.native_trace_many(trace_two(), config_two(), 502, 20), 321)

    def test_missing_duplicate_or_reordered_interface_fails(self) -> None:
        lines = trace_two().splitlines()
        interface_1 = lines[4]
        variants = [
            '\n'.join(lines[:4] + lines[5:]),
            trace_two() + interface_1 + '\n',
            '\n'.join(lines[:3] + [lines[5], lines[3], lines[4]] + lines[6:]),
        ]
        for value in variants:
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                acceptance.native_trace_many(value, config_two(), 502, 20)

    def test_interface_attestation_must_match_config(self) -> None:
        for old, new in [('network_index=1', 'network_index=2'),
                         ('gateway=10.250.41.1', 'gateway=10.250.99.1'),
                         ('isolated=true', 'isolated=false')]:
            with self.subTest(old=old), self.assertRaises(RuntimeError):
                acceptance.native_trace_many(trace_two().replace(old, new), config_two(), 502, 20)


class LegacyRemovalTests(unittest.TestCase):
    def test_legacy_scan_ignores_docs_and_validation_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Sources').mkdir()
            (root / 'plugin').mkdir()
            (root / 'scripts').mkdir()
            (root / 'Sources/native.swift').write_text('krun_add_net_vmnet_shared')
            (root / 'docs').mkdir()
            (root / 'docs/history.md').write_text('vmnet-helper krun_add_net_unixgram')
            (root / 'mise.toml').write_text('native = true')
            (root / 'scripts/install_native_vmnet.sh').write_text('native')
            (root / 'scripts/build_native_libkrun.sh').write_text('native')
            self.assertEqual(acceptance.legacy_source_violations(root), [])

    def test_legacy_scan_rejects_production_backend_references(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Sources').mkdir()
            (root / 'plugin').mkdir()
            (root / 'scripts').mkdir()
            (root / 'Sources/backend.swift').write_text('vmnet-helper\nkrun_add_net_unixgram\n')
            (root / 'mise.toml').write_text('native')
            (root / 'scripts/install_native_vmnet.sh').write_text('native')
            (root / 'scripts/build_native_libkrun.sh').write_text('native')
            violations = acceptance.legacy_source_violations(root)
            self.assertEqual(len(violations), 2)
            self.assertTrue(all(value.startswith('Sources/backend.swift:') for value in violations))


class RouteValidationTests(unittest.TestCase):
    def test_connected_route_accepts_direct_kernel_route(self) -> None:
        routes = (
            'default via 10.250.40.1 dev eth0\n'
            '10.250.40.0/24 dev eth0 scope link src 10.250.40.2\n'
            '10.250.41.0/24 dev eth1 scope link src 10.250.41.2\n'
        )
        self.assertTrue(
            acceptance.has_connected_route(routes, acceptance.ipaddress.IPv4Network('10.250.41.0/24'), 'eth1')
        )

    def test_connected_route_rejects_wrong_network_or_device(self) -> None:
        routes = '10.250.41.0/24 dev eth1 scope link src 10.250.41.2\n'
        self.assertFalse(
            acceptance.has_connected_route(routes, acceptance.ipaddress.IPv4Network('10.250.42.0/24'), 'eth1')
        )
        self.assertFalse(
            acceptance.has_connected_route(routes, acceptance.ipaddress.IPv4Network('10.250.41.0/24'), 'eth0')
        )


class EchoHelperTests(unittest.TestCase):
    def test_recv_exact_accumulates_tcp_fragments(self) -> None:
        class FragmentedSocket:
            def __init__(self) -> None:
                self.fragments = [b'ab', b'c', b'def']

            def recv(self, _length: int) -> bytes:
                return self.fragments.pop(0) if self.fragments else b''

        self.assertEqual(acceptance.recv_exact(FragmentedSocket(), 6), b'abcdef')

    def test_recv_exact_reports_early_eof_without_padding(self) -> None:
        class ShortSocket:
            def __init__(self) -> None:
                self.fragments = [b'ab', b'']

            def recv(self, _length: int) -> bytes:
                return self.fragments.pop(0)

        self.assertEqual(acceptance.recv_exact(ShortSocket(), 4), b'ab')

    def test_port_phase_checks_direct_echo_before_publication(self) -> None:
        source = Path(acceptance.__file__).read_text()
        direct = source.index("description='direct guest TCP echo'")
        published = source.index('tcp_echo(tcp_port, tcp_payload)')
        diagnostics = source.index('capture_port_diagnostics(run, evidence)')
        self.assertLess(direct, published)
        self.assertGreater(diagnostics, published)


class AcceptanceShapeTests(unittest.TestCase):
    def test_container_attachments_requires_live_networks(self) -> None:
        good = [{'status': {'networks': [{'ipv4Address': '10.0.0.2/24'}]}}]
        self.assertEqual(len(acceptance.container_attachments(good)), 1)
        for bad in ([], [{}, {}], [{'status': {'networks': []}}]):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                acceptance.container_attachments(bad)

    def test_regression_set_does_not_call_superseded_helper_specific_network_scripts(self) -> None:
        source = Path(acceptance.__file__).read_text()
        for path in ('validate_networking.sh', 'validate_multiple_networks.sh', 'validate_port_forwarding.sh'):
            self.assertNotIn(f"('network-regression', ['scripts/{path}'", source)
        for path in ('validate_runtime_regression.sh', 'validate_init.sh', 'validate_copy.sh',
                     'validate_volumes.sh', 'validate_unix_sockets.sh', 'validate_virtiofs.sh',
                     'validate_logs_clean.sh', 'validate_snapshot.sh', 'validate_fail_closed.sh'):
            self.assertIn(path, source)


if __name__ == '__main__':
    unittest.main()
