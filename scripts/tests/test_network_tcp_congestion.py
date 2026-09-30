"""Keep congestion-control experiments socket-scoped, explicit, and verifiable."""

import contextlib
import importlib.util
import io
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).parents[1] / "benchmark_network_streams.py"
SPEC = importlib.util.spec_from_file_location("tcp_congestion_bench", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)


class SourceConnectionTests(unittest.TestCase):
    def namespace(self, algorithm="cubic"):
        namespace = {}
        with mock.patch.object(sys, "argv", ["source", "127.0.0.1", "1234", "1", "1", "1024", "0", algorithm]):
            exec(compile(bench.GUEST_SOURCE.split("\nthreads = ", 1)[0], "<guest-source>", "exec"), namespace)
        return namespace

    def test_default_keeps_existing_connection_path(self):
        ns = self.namespace("default")
        with mock.patch.object(socket, "create_connection") as connect, mock.patch.object(socket, "socket") as new:
            self.assertIs(ns["source_connection"](0), connect.return_value)
        connect.assert_called_once_with(("127.0.0.1", 1234), timeout=30)
        new.assert_not_called()
        self.assertFalse(ns["tcp_congestion_flows"])

    def test_override_is_set_and_verified_before_connect(self):
        ns = self.namespace()
        sock = mock.Mock()
        sock.getsockopt.return_value = b"cubic\0"
        with mock.patch.object(socket, "socket", return_value=sock), \
             mock.patch.object(socket, "TCP_CONGESTION", 13, create=True):
            self.assertIs(ns["source_connection"](4), sock)
        self.assertEqual(sock.mock_calls, [
            mock.call.settimeout(30),
            mock.call.setsockopt(socket.IPPROTO_TCP, 13, b"cubic"),
            mock.call.getsockopt(socket.IPPROTO_TCP, 13, 64),
            mock.call.connect(("127.0.0.1", 1234)),
        ])
        self.assertEqual(ns["tcp_congestion_flows"][4], {"stream_id": 4, "algorithm": "cubic"})

    def test_unavailable_algorithm_closes_socket_without_connecting_or_fallback(self):
        ns = self.namespace()
        sock = mock.Mock()
        sock.setsockopt.side_effect = OSError("not available")
        with mock.patch.object(socket, "socket", return_value=sock), \
             mock.patch.object(socket, "TCP_CONGESTION", 13, create=True), \
             mock.patch.object(pathlib.Path, "read_text", return_value="reno bbr\n"):
            with self.assertRaisesRegex(RuntimeError, "registered algorithms: reno bbr; no fallback"):
                ns["source_connection"](0)
        sock.connect.assert_not_called()
        sock.close.assert_called_once()
        self.assertFalse(ns["tcp_congestion_flows"])

    def test_mismatched_algorithm_is_not_used(self):
        ns = self.namespace()
        sock = mock.Mock()
        sock.getsockopt.return_value = b"reno\0"
        with mock.patch.object(socket, "socket", return_value=sock), \
             mock.patch.object(socket, "TCP_CONGESTION", 13, create=True):
            with self.assertRaisesRegex(RuntimeError, "got 'reno'"):
                ns["source_connection"](0)
        sock.connect.assert_not_called()
        sock.close.assert_called_once()

    def test_connection_error_remains_connection_error(self):
        ns = self.namespace()
        sock = mock.Mock()
        sock.getsockopt.return_value = b"cubic\0"
        sock.connect.side_effect = ConnectionRefusedError("refused")
        with mock.patch.object(socket, "socket", return_value=sock), \
             mock.patch.object(socket, "TCP_CONGESTION", 13, create=True):
            with self.assertRaises(ConnectionRefusedError):
                ns["source_connection"](0)
        sock.close.assert_called_once()
        self.assertFalse(ns["tcp_congestion_flows"])


class SelectionEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = pathlib.Path(self.temp.name)
        self.benchmark = bench.Benchmark(self.output, timeout=10)
        self.benchmark.tcp_congestion = "cubic"
        self.endpoint = bench.Endpoint("test", "r1", "192.0.2.2", "192.0.2.1", 8090)
        self.payload = {"mib_per_second": 1.0, "tcp_congestion": {
            "requested": "cubic", "flows": [{"stream_id": 0, "algorithm": "cubic"}],
        }}

    def save(self):
        bench.save_tcp_congestion_evidence(self.benchmark, self.endpoint, "sample", self.payload, 1)
        return json.loads((self.output / "sample-tcp-congestion.json").read_text())

    def test_verified_selection_saved_without_tcp_sampling(self):
        saved = self.save()
        self.assertFalse(saved["validation_errors"])
        self.assertEqual(saved["requested"], "cubic")
        self.assertEqual(saved["flows"], self.payload["tcp_congestion"]["flows"])
        self.assertEqual(saved["endpoint"]["container_id"], "r1")
        self.assertEqual(self.benchmark.tcp_info_interval_ms, 0)

    def test_missing_selection_export_is_not_silently_accepted(self):
        del self.payload["tcp_congestion"]
        with self.assertRaisesRegex(RuntimeError, "did not export"):
            self.save()

    def test_bad_selections_fail_after_preserving_evidence(self):
        invalid = [
            {"requested": "bbr", "flows": [{"stream_id": 0, "algorithm": "cubic"}]},
            {"requested": "cubic", "flows": [{"stream_id": 0, "algorithm": "bbr"}]},
            {"requested": "cubic", "flows": []},
            {"requested": "cubic", "flows": [None]},
            {"requested": "cubic", "flows": [{"stream_id": [], "algorithm": "cubic"}]},
            {"requested": "cubic", "flows": [{"stream_id": 1, "algorithm": "cubic"}]},
            {"requested": "cubic", "flows": [{"stream_id": 0, "algorithm": "cubic"}] * 2},
        ]
        for capture in invalid:
            with self.subTest(capture=capture):
                self.payload["tcp_congestion"] = capture
                with self.assertRaisesRegex(RuntimeError, "invalid TCP congestion selection"):
                    self.save()
                saved = json.loads((self.output / "sample-tcp-congestion.json").read_text())
                self.assertTrue(saved["validation_errors"])

    def test_guest_argv_reserves_interval_slot_without_sampling(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(self.payload), "")
        with mock.patch.object(self.benchmark, "run", return_value=result) as run:
            bench.guest_source(self.benchmark, self.endpoint, "192.0.2.1", 8090, 1, 20, 1024, "sample")
        self.assertEqual(run.call_args.args[1][-3:], ["1024", "0", "cubic"])
        self.assertTrue((self.output / "sample-tcp-congestion.json").exists())

    def test_live_capture_must_match_the_selected_algorithm(self):
        self.benchmark.tcp_info_interval_ms = 100
        self.payload["tcp_flow"] = {"byteorder": "little", "flows": [{
            "stream_id": 0, "congestion_control": "bbr",
            "snapshots": [{"phase": "sending", "tcp_info_hex": bytes(256).hex()}],
        }], "errors": []}
        with self.assertRaisesRegex(RuntimeError, "incomplete TCP flow evidence"):
            bench.save_tcp_flow_evidence(self.benchmark, self.endpoint, "sample", self.payload, 1, 20)
        saved = json.loads((self.output / "sample-tcp-flow.json").read_text())
        self.assertIn("unexpected live congestion", saved["validation_errors"][0])


class CommandTests(unittest.TestCase):
    def test_invalid_and_reverse_only_selection_fail_before_container_creation(self):
        for args in (("--tcp-congestion", "unknown"),
                     ("--tcp-congestion", "cubic", "--direction", "host_to_guest")):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, str(SCRIPT), *args],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("RUN ", result.stdout)

    def test_main_records_algorithm_in_metadata_and_benchmark(self):
        for algorithm in ("default", "bbr", "cubic", "reno"):
            with self.subTest(algorithm=algorithm), tempfile.TemporaryDirectory() as directory:
                endpoint = bench.Endpoint("test", "test", "192.0.2.2", "192.0.2.1", 8090)
                args = [str(SCRIPT), "--tcp-congestion", algorithm, "--direction", "guest_to_host",
                        "--streams", "1", "--iterations", "1", "--result-root", directory]
                with mock.patch.object(sys, "argv", args), \
                     mock.patch.object(bench, "start_endpoint", return_value=endpoint), \
                     mock.patch.object(bench, "git_head", return_value="test"), \
                     mock.patch.object(bench, "run_direction") as measure, \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(bench.main(), 0)
                self.assertEqual(measure.call_args.args[0].tcp_congestion, algorithm)
                metadata = json.loads(next(pathlib.Path(directory).glob("*/metadata.json")).read_text())
                self.assertEqual(metadata["tcp_congestion"], algorithm)


@unittest.skipUnless(sys.platform.startswith("linux") and hasattr(socket, "TCP_CONGESTION"),
                     "requires Linux guest congestion-control socket API")
class LoopbackTests(unittest.TestCase):
    def test_actual_guest_sender_reno_with_and_without_live_sampling(self):
        for interval in (0, 100):
            with self.subTest(interval=interval), tempfile.TemporaryDirectory() as directory:
                output = pathlib.Path(directory)
                host_path = output / "host.json"
                with bench.SinkServer("127.0.0.1", evidence_path=host_path) as sink:
                    result = subprocess.run(
                        [sys.executable, "-c", bench.GUEST_SOURCE, "127.0.0.1", str(sink.port),
                         "2", "0.6", "16384", str(interval), "reno"],
                        capture_output=True, text=True, timeout=10, check=True,
                    )
                self.assertFalse(result.stderr)
                payload = json.loads(result.stdout)
                expected = [{"stream_id": n, "algorithm": "reno"} for n in range(2)]
                self.assertEqual(payload["tcp_congestion"]["flows"], expected)
                host = json.loads(host_path.read_text())
                self.assertEqual(sum(c["received_payload_bytes"] for c in host["connections"]), payload["bytes"])
                self.assertTrue(all(c["ack_sent"] for c in host["connections"]))
                self.assertFalse(host["errors"])
                benchmark = bench.Benchmark(output, timeout=10)
                benchmark.tcp_congestion = "reno"
                benchmark.tcp_info_interval_ms = interval
                endpoint = bench.Endpoint("test", "test", "127.0.0.1", "127.0.0.1", sink.port)
                bench.save_tcp_congestion_evidence(benchmark, endpoint, "sample", payload, 2)
                if interval:
                    self.assertTrue(all(f["congestion_control"] == "reno" for f in payload["tcp_flow"]["flows"]))
                    bench.save_tcp_flow_evidence(benchmark, endpoint, "sample", payload, 2, 0.6)
                else:
                    self.assertNotIn("tcp_flow", payload)

    def test_actual_guest_fails_unavailable_selection_before_any_connection(self):
        with bench.SinkServer("127.0.0.1") as sink:
            result = subprocess.run(
                [sys.executable, "-c", bench.GUEST_SOURCE, "127.0.0.1", str(sink.port),
                 "2", "0.1", "16384", "0", "krun_no_such_cc"],
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no fallback was used", result.stderr)
        self.assertEqual(sink.connections, [])
        self.assertFalse(result.stdout)


if __name__ == "__main__":
    unittest.main()
