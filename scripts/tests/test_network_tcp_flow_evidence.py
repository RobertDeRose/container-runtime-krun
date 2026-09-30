"""Exercise the actual Linux guest sender and its opt-in TCP diagnostics."""

import contextlib
import copy
import io
import importlib.util
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).parents[1] / "benchmark_network_streams.py"
SPEC = importlib.util.spec_from_file_location("tcp_flow_bench", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)


class TcpInfoDecoderTests(unittest.TestCase):
    def test_both_guest_byte_orders_and_wide_counters(self):
        for byteorder in ("little", "big"):
            with self.subTest(byteorder=byteorder):
                raw = bytearray(256)
                values = {"tcpi_snd_cwnd": 123, "tcpi_rtt": 456,
                          "tcpi_bytes_acked": (1 << 40) + 7, "tcpi_snd_wnd": 987654}
                for field, value in values.items():
                    offset, size = bench.TCP_INFO_FIELDS[field]
                    raw[offset:offset + size] = value.to_bytes(size, byteorder)
                result = bench.decode_tcp_info(raw.hex(), byteorder)
                for field, value in values.items():
                    self.assertEqual(result[field], value)

    def test_short_kernel_struct_has_null_tail_fields_not_zeroes(self):
        result = bench.decode_tcp_info(bytes(104).hex(), "little")
        self.assertEqual(result["tcpi_total_retrans"], 0)
        self.assertIsNone(result["tcpi_pacing_rate"])
        self.assertIsNone(result["tcpi_snd_wnd"])

    def test_partial_tail_field_is_not_decoded(self):
        result = bench.decode_tcp_info(bytes(231).hex(), "little")
        self.assertIsNone(result["tcpi_snd_wnd"])
        self.assertEqual(result["tcpi_bytes_retrans"], 0)

    def test_invalid_input_fails_explicitly(self):
        for raw, byteorder in (("xyz", "little"), ("00", "little"), ("00" * 256, "unknown")):
            with self.subTest(raw=raw[:5], byteorder=byteorder), self.assertRaises(ValueError):
                bench.decode_tcp_info(raw, byteorder)


class TcpFlowArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = pathlib.Path(self.temp.name)
        self.benchmark = bench.Benchmark(self.output, timeout=10)
        self.benchmark.tcp_info_interval_ms = 250
        self.endpoint = bench.Endpoint("apple", "test-r1", "192.0.2.2", "192.0.2.1", 8090)
        self.payload = {
            "bytes": 1024, "streams": 1, "elapsed_seconds": 1.0,
            "completion_elapsed_seconds": 1.01, "mib_per_second": 1.0,
            "tcp_flow": {"schema_version": 1, "interval_ms": 250,
                         "byteorder": "little", "flows": [{"stream_id": 0, "snapshots": [
                             {"phase": "sending", "tcp_info_hex": bytes(256).hex()},
                         ]}], "errors": []},
        }

    def save(self):
        bench.save_tcp_flow_evidence(
            self.benchmark, self.endpoint, "sample", self.payload, 1, 20,
        )
        return json.loads((self.output / "sample-tcp-flow.json").read_text())

    def test_success_preserves_raw_bytes_and_decodes_after_measurement(self):
        evidence = self.save()
        self.assertEqual(evidence["endpoint"]["runtime"], "apple")
        self.assertEqual(evidence["throughput_mib_per_second"], 1.0)
        row = evidence["flows"][0]["snapshots"][0]
        self.assertEqual(row["tcp_info_hex"], bytes(256).hex())
        self.assertEqual(row["tcp_info"]["tcpi_snd_wnd"], 0)
        self.assertFalse(evidence["validation_errors"])

    def test_missing_export_fails(self):
        del self.payload["tcp_flow"]
        with self.assertRaisesRegex(RuntimeError, "did not export"):
            self.save()

    def test_errors_and_missing_coverage_fail_after_preserving_raw_evidence(self):
        for change in ("errors", "empty", "not-live", "malformed"):
            with self.subTest(change=change):
                original = copy.deepcopy(self.payload)
                capture = self.payload["tcp_flow"]
                if change == "errors":
                    capture["errors"].append("getsockopt failed")
                elif change == "empty":
                    capture["flows"].clear()
                elif change == "not-live":
                    capture["flows"][0]["snapshots"][0]["phase"] = "payload_end"
                else:
                    capture["flows"][0]["snapshots"][0]["tcp_info_hex"] = "00"
                with self.assertRaisesRegex(RuntimeError, "incomplete TCP flow evidence"):
                    self.save()
                saved = json.loads((self.output / "sample-tcp-flow.json").read_text())
                self.assertTrue(saved["validation_errors"])
                self.payload = original

    def test_guest_argv_passes_interval_only_when_enabled(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                self.benchmark.tcp_info_interval_ms = 250 if enabled else 0
                payload = copy.deepcopy(self.payload)
                if not enabled:
                    del payload["tcp_flow"]
                result = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
                with mock.patch.object(self.benchmark, "run", return_value=result) as run:
                    bench.guest_source(self.benchmark, self.endpoint, "192.0.2.1", 8090,
                                       1, 20, 1024, "sample")
                argv = run.call_args.args[1]
                self.assertEqual(argv[-1], "250" if enabled else "1024")


class TcpFlowCommandTests(unittest.TestCase):
    def test_invalid_sampling_intervals_rejected_before_creating_containers(self):
        for interval in (-1, 1, 99):
            result = subprocess.run([sys.executable, str(SCRIPT), "--tcp-info-interval-ms", str(interval)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn("at least 100", result.stderr)

    def test_tcp_capture_is_not_silently_ignored_for_reverse_only_run(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--tcp-info-interval-ms", "250",
                                 "--direction", "host_to_guest"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires the guest_to_host direction", result.stderr)

    def test_main_selects_directions_and_archives_sampling_metadata(self):
        for selected, expected in (("both", ["guest_to_host", "host_to_guest"]),
                                   ("guest_to_host", ["guest_to_host"]),
                                   ("host_to_guest", ["host_to_guest"])):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as directory:
                args = [str(SCRIPT), "--direction", selected, "--streams", "1",
                        "--iterations", "1", "--result-root", directory]
                if selected == "guest_to_host":
                    args.extend(["--tcp-info-interval-ms", "250"])
                endpoint = bench.Endpoint("test", "test", "192.0.2.2", "192.0.2.1", 8090)
                with mock.patch.object(sys, "argv", args), \
                     mock.patch.object(bench, "start_endpoint", return_value=endpoint), \
                     mock.patch.object(bench, "git_head", return_value="test"), \
                     mock.patch.object(bench, "run_direction") as measure, \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(bench.main(), 0)
                self.assertEqual([call.args[2] for call in measure.call_args_list], expected)
                metadata = json.loads(next(pathlib.Path(directory).glob("*/metadata.json")).read_text())
                self.assertEqual(metadata["direction"], selected)
                self.assertEqual(metadata["tcp_info_interval_ms"], 250 if selected == "guest_to_host" else 0)
                self.assertTrue(list(pathlib.Path(directory).glob("*.tar.gz")))

    def test_sender_payload_loop_is_unchanged(self):
        self.assertIn('''                while time.perf_counter_ns() < deadline:
                    sock.sendall(chunk)
                    sent += len(chunk)
                send_end_ns = time.perf_counter_ns()''', bench.GUEST_SOURCE)


@unittest.skipUnless(sys.platform.startswith("linux") and hasattr(socket, "TCP_INFO"),
                     "embedded sender requires the Linux guest TCP_INFO API")
class TcpFlowLoopbackTests(unittest.TestCase):
    def test_exact_guest_source_samples_live_flows_and_verifies_all_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            sink_path = output / "host.json"
            with bench.SinkServer("127.0.0.1", evidence_path=sink_path) as sink:
                result = subprocess.run(
                    [sys.executable, "-c", bench.GUEST_SOURCE, "127.0.0.1", str(sink.port),
                     "2", "0.8", "16384", "100"],
                    capture_output=True, text=True, timeout=10, check=True,
                )
            self.assertFalse(result.stderr)
            payload = json.loads(result.stdout)
            capture = payload["tcp_flow"]
            self.assertEqual(capture["interval_ms"], 100)
            self.assertEqual(len(capture["flows"]), 2)
            self.assertFalse(capture["errors"])
            for flow in capture["flows"]:
                phases = [row["phase"] for row in flow["snapshots"]]
                self.assertEqual(phases[0], "connected")
                self.assertEqual(phases[-1], "complete")
                self.assertEqual(phases.count("payload_end"), 1)
                self.assertLess(phases.index("payload_end"), len(phases) - 1)
                self.assertIn("sending", phases)
                self.assertTrue(flow["congestion_control"])
                self.assertGreater(flow["send_buffer_bytes"], 0)
                for row in flow["snapshots"]:
                    self.assertGreaterEqual(row["getsockopt_ns"], 0)
                    decoded = bench.decode_tcp_info(row["tcp_info_hex"], capture["byteorder"])
                    self.assertGreater(decoded["tcpi_snd_cwnd"], 0)
            host = json.loads(sink_path.read_text())
            self.assertEqual(sum(row["received_payload_bytes"] for row in host["connections"]),
                             payload["bytes"])
            self.assertTrue(all(row["ack_sent"] for row in host["connections"]))
            self.assertFalse(host["errors"])
            benchmark = bench.Benchmark(output, timeout=10)
            benchmark.tcp_info_interval_ms = 100
            endpoint = bench.Endpoint("test", "test", "127.0.0.1", "127.0.0.1", 8090)
            bench.save_tcp_flow_evidence(benchmark, endpoint, "test", payload, 2, 0.8)
            saved = json.loads((output / "test-tcp-flow.json").read_text())
            self.assertFalse(saved["validation_errors"])


if __name__ == "__main__":
    unittest.main()
