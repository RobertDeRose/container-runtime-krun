from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macho_trust as macho
import native_vmnet_validation as validation


def config() -> dict:
    return {'networks': [{'ipv4Gateway': '192.168.200.1', 'ipv4Mask': '255.255.255.0',
                           'macAddress': [2, 0, 0, 0, 0, 1], 'features': 0, 'flags': 0}]}


def trace() -> str:
    return f'''helper lifecycle [event=helper start] [pid=123] [uid=0] [euid=0]
helper lifecycle [event=libkrun loaded] [path={validation.LIBRARY}]
helper lifecycle [event=context created] [default_firmware=disabled]
helper lifecycle [event=native vmnet interface ready] [backend=libkrun-vmnet-shared] [api=krun_add_net_vmnet_shared] [network_index=0] [features=0] [flags=0] [gateway=192.168.200.1] [netmask=255.255.255.0] [dhcp=false] [isolated=true]
helper lifecycle [event=helper privileges dropped] [pid=123] [uid=502] [euid=502] [gid=20] [egid=20] [root_regain_blocked=true]
helper lifecycle [event=basic VM configuration complete]
helper lifecycle [event=device configuration complete]
helper lifecycle [event=krun_start_enter start]
'''


class NativeTraceTests(unittest.TestCase):
    def test_native_trace(self) -> None:
        self.assertEqual(validation.native_trace(trace(), config(), 502, 20), 123)

    def test_missing_or_duplicate_native_event(self) -> None:
        line = trace().splitlines()[3]
        for changed in (trace().replace(line, ''), trace() + line):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                validation.native_trace(changed, config(), 502, 20)

    def test_wrong_attestation(self) -> None:
        for old, new in [('euid=502', 'euid=0'), ('default_firmware=disabled', 'default_firmware=enabled'),
                         ('root_regain_blocked=true', 'root_regain_blocked=false'),
                         ('api=krun_add_net_vmnet_shared', 'api=krun_add_net_unixgram'),
                         ('isolated=true', 'isolated=false'), ('flags=0', 'flags=1')]:
            with self.subTest(old=old), self.assertRaises(RuntimeError):
                validation.native_trace(trace().replace(old, new), config(), 502, 20)

    def test_drop_after_guest_start_fails(self) -> None:
        lines = trace().splitlines()
        lines[4], lines[7] = lines[7], lines[4]
        with self.assertRaises(RuntimeError):
            validation.native_trace('\n'.join(lines), config(), 502, 20)

    def test_config_must_be_one_native_nic(self) -> None:
        for mutation in ('second', 'socket', 'offload'):
            value = config()
            if mutation == 'second':
                value['networks'].append(copy.deepcopy(value['networks'][0]))
            elif mutation == 'socket':
                value['networks'][0]['socketPath'] = '/tmp/old.sock'
            else:
                value['networks'][0]['features'] = 1
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                validation.native_trace(trace(), value, 502, 20)

    def test_quarantine_is_never_a_pass(self) -> None:
        with self.assertRaises(RuntimeError):
            validation.native_trace(trace() + 'native resources retained until process exit', config(), 502, 20)

    def test_vmm_stop_requires_success_and_exit_observer_path(self) -> None:
        good = trace() + 'helper lifecycle [event=VMM stop requested] [result=0]\nVmm is stopping.\n'
        validation.vmm_stop_evidence(good)
        for bad in (trace(), good.replace('[result=0]', '[result=-2]'), good.replace('Vmm is stopping.', '')):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                validation.vmm_stop_evidence(bad)

    def test_apple_allocation(self) -> None:
        attachment = {'variant': 'allocationOnly', 'ipv4Address': '192.168.200.2/24',
                      'ipv4Gateway': '192.168.200.1', 'macAddress': '02:00:00:00:00:01', 'mtu': 1500}
        value = [{'status': {'networks': [attachment]}}]
        self.assertEqual(validation.network_attachment(value, config()),
                         ('192.168.200.2/24', '192.168.200.1', '02:00:00:00:00:01', 1500))
        for key, replacement in [('variant', 'reserved'), ('macAddress', '02:00:00:00:00:02'),
                                 ('ipv4Gateway', '192.168.201.1'), ('ipv4Address', '192.168.200.2/25')]:
            bad = copy.deepcopy(value)
            bad[0]['status']['networks'][0][key] = replacement
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validation.network_attachment(bad, config())

    def test_stats_require_both_counters_and_identity(self) -> None:
        before = [{'id': 'test', 'networkRxBytes': 10, 'networkTxBytes': 20}]
        after = [{'id': 'test', 'networkRxBytes': 20, 'networkTxBytes': 30}]
        validation.assert_counters(before, after, 'test')
        for update in ({'networkTxBytes': 20}, {'networkRxBytes': None}, {'id': 'other'}, {'networkRxBytes': True}):
            bad = [after[0] | update]
            with self.subTest(update=update), self.assertRaises(RuntimeError):
                validation.assert_counters(before, bad, 'test')

    def test_validation_workload_does_not_require_httpd_to_stay_alive(self) -> None:
        self.assertEqual(validation.guest_keepalive_command(),
                         ['sh', '-c', 'while :; do sleep 3600; done'])
        command = validation.guest_http_command('token with spaces')
        self.assertEqual(command[-1], 'token with spaces')
        self.assertNotIn('token with spaces', command[2])
        self.assertIn('apk add --no-cache busybox-extras', command[2])
        self.assertIn('httpd -p 8080 -h /www', command[2])

    def test_managed_exit_status_reports_last_guest_exit(self) -> None:
        self.assertIsNone(validation.managed_process_exit_status(trace()))
        self.assertEqual(validation.managed_process_exit_status(
            'status: 23 managed process exit\nstatus: 127 managed process exit\n'), 127)

    def test_helper_detection_does_not_confuse_apple_network_service(self) -> None:
        values = validation.processes('1 0 0 0 /usr/libexec/container-network-vmnet start\n'
                                      '2 1 0 0 /opt/homebrew/bin/vmnet-helper --socket /tmp/a\n'
                                      '3 1 502 20 /Library/container-krun-vmm-helper /path with spaces/a.json\n')
        self.assertEqual(validation.external_helpers(values), {2})
        self.assertEqual(values[3][0:2], (502, 20))

    def test_provenance_rejects_duplicate_or_dirty_source(self) -> None:
        text = '\n'.join(['commit=' + 'a' * 40, 'sha256=' + 'b' * 64, 'helper_sha256=' + 'c' * 64,
                          'runtime_sha256=' + 'd' * 64, 'source_build_sha256=' + 'e' * 64,
                          'source_dirty=false', 'backend=libkrun-vmnet-shared', 'features=BLK=1 NET=1'])
        validation.provenance(text)
        for bad in (text + '\ncommit=' + 'f' * 40, text.replace('source_dirty=false', 'source_dirty=true')):
            with self.assertRaises(RuntimeError):
                validation.provenance(bad)


class MachOTests(unittest.TestCase):
    def test_parse_dependency_commands_not_self_id(self) -> None:
        text = '''Load command 0
 cmd LC_ID_DYLIB
 name libkrun.1.dylib (offset 24)
Load command 1
 cmd LC_LOAD_DYLIB
 name /usr/lib/libSystem.B.dylib (offset 24)
Load command 2
 cmd LC_RPATH
 path /home/developer/toolchain (offset 12)
'''
        self.assertEqual(macho.parse_load_commands(text),
                         (['/usr/lib/libSystem.B.dylib'], ['/home/developer/toolchain']))

    def test_embedded_environment_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            macho.parse_load_commands('cmd LC_DYLD_ENVIRONMENT\n')

    def test_library_paths(self) -> None:
        self.assertTrue(macho.trusted_system_library('/usr/lib/swift/libswiftCore.dylib'))
        for value in ('@rpath/libkrunfw.dylib', '/opt/homebrew/lib/libffi.dylib', '/usr/lib/../../tmp/evil',
                      '/System/LibraryEvil/code', '/usr/liberty/code'):
            self.assertFalse(macho.trusted_system_library(value), value)


class BoundedCommandTests(unittest.TestCase):
    def test_preserves_nonzero_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = validation.run_command([sys.executable, '-c', 'print("details"); raise SystemExit(23)'],
                                            Path(directory) / 'run.txt', 2)
            self.assertEqual(result.code, 23)
            self.assertIn('details', result.output)

    def test_timeout_kills_sigterm_ignoring_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            start = time.monotonic()
            result = validation.run_command([sys.executable, '-c',
                'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'],
                Path(directory) / 'run.txt', 0.2)
            self.assertEqual(result.code, 124)
            self.assertTrue(result.timed_out)
            self.assertLess(time.monotonic() - start, 4)

    def test_local_host_server_serves_only_token(self) -> None:
        import urllib.error
        import urllib.request
        with validation.host_server('127.0.0.1', 'native-test') as port:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/native-test', timeout=2) as response:
                self.assertEqual(response.read(), b'native-test')
            with self.assertRaises(urllib.error.HTTPError):
                urllib.request.urlopen(f'http://127.0.0.1:{port}/etc/passwd', timeout=2)


if __name__ == '__main__':
    unittest.main()
