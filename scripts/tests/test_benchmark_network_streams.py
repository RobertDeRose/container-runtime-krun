import argparse
import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "benchmark_network_streams.py"
SPEC = importlib.util.spec_from_file_location("benchmark_network_streams", SCRIPT)
assert SPEC and SPEC.loader
network_streams = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = network_streams
SPEC.loader.exec_module(network_streams)


class StreamParsingTests(unittest.TestCase):
    def test_parse_streams(self):
        self.assertEqual(network_streams.parse_streams("1,4,8"), [1, 4, 8])
        self.assertEqual(network_streams.parse_streams(" 2, 6 "), [2, 6])

    def test_parse_streams_rejects_invalid_values(self):
        for value in ("", "0", "1,-2", "abc"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    network_streams.parse_streams(value)


class EndpointNamingTests(unittest.TestCase):
    def test_runtime_labels_do_not_expand_container_ids(self):
        original_run = network_streams.Benchmark.run
        original_wait_ready = network_streams.wait_ready
        original_inspect_endpoint = network_streams.inspect_endpoint
        original_free_tcp_port = network_streams.free_tcp_port
        seen: list[str] = []

        def fake_run(bench, label, command, **kwargs):
            seen.append(command[command.index("--name") + 1])
            return type("Result", (), {"stdout": "", "stderr": "", "returncode": 0})()

        try:
            network_streams.Benchmark.run = fake_run
            network_streams.wait_ready = lambda _bench, _container_id: None
            network_streams.inspect_endpoint = lambda _bench, _container_id: (
                "192.0.2.2",
                "192.0.2.1",
            )
            network_streams.free_tcp_port = lambda: 54321
            with tempfile.TemporaryDirectory() as temp_dir:
                bench = network_streams.Benchmark(pathlib.Path(temp_dir), timeout=5)
                endpoint = network_streams.start_endpoint(
                    bench,
                    "container-runtime-krun",
                    "krun-vmnet-helper-offload",
                    "python:3.13-alpine",
                    "default",
                    "krun-streams-20260927t022723z-70871",
                    2,
                    8,
                )
        finally:
            network_streams.Benchmark.run = original_run
            network_streams.wait_ready = original_wait_ready
            network_streams.inspect_endpoint = original_inspect_endpoint
            network_streams.free_tcp_port = original_free_tcp_port

        self.assertEqual(endpoint.container_id, "krun-streams-20260927t022723z-70871-r2")
        self.assertEqual(seen, [endpoint.container_id])
        self.assertLessEqual(len(endpoint.container_id), 63)

    def test_runtime_cpu_count_is_forwarded_to_container_run(self):
        original_run = network_streams.Benchmark.run
        original_wait_ready = network_streams.wait_ready
        original_inspect_endpoint = network_streams.inspect_endpoint
        original_free_tcp_port = network_streams.free_tcp_port
        seen: list[list[str]] = []

        def fake_run(bench, label, command, **kwargs):
            seen.append(command)
            return type("Result", (), {"stdout": "", "stderr": "", "returncode": 0})()

        try:
            network_streams.Benchmark.run = fake_run
            network_streams.wait_ready = lambda _bench, _container_id: None
            network_streams.inspect_endpoint = lambda _bench, _container_id: (
                "192.0.2.2",
                "192.0.2.1",
            )
            network_streams.free_tcp_port = lambda: 54321
            with tempfile.TemporaryDirectory() as temp_dir:
                bench = network_streams.Benchmark(pathlib.Path(temp_dir), timeout=5)
                network_streams.start_endpoint(
                    bench,
                    "container-runtime-krun",
                    "krun-native-cpu8",
                    "python:3.13-alpine",
                    "default",
                    "krun-streams-test",
                    2,
                    8,
                )
        finally:
            network_streams.Benchmark.run = original_run
            network_streams.wait_ready = original_wait_ready
            network_streams.inspect_endpoint = original_inspect_endpoint
            network_streams.free_tcp_port = original_free_tcp_port

        command = seen[0]
        self.assertEqual(command[command.index("--cpus") + 1], "8")


class BackendSelectionTests(unittest.TestCase):
    def test_configure_runtime_backend_toggles_marker(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            marker = pathlib.Path(temp_dir) / ".vmnet-helper-control"
            network_streams.configure_runtime_backend(marker, "vmnet-helper")
            self.assertEqual(marker.read_text(), "vmnet-helper-control-v1\n")
            network_streams.configure_runtime_backend(marker, "native")
            self.assertFalse(marker.exists())

    def test_non_default_backend_requires_marker(self):
        with self.assertRaises(RuntimeError):
            network_streams.configure_runtime_backend(None, "vmnet-helper")



class CleanupTests(unittest.TestCase):
    def test_cleanup_timeout_is_recorded_without_raising(self):
        original = network_streams.subprocess.run

        def timed_out(*args, **kwargs):
            raise network_streams.subprocess.TimeoutExpired(args[0], 30)

        try:
            network_streams.subprocess.run = timed_out
            with tempfile.TemporaryDirectory() as temp_dir:
                bench = network_streams.Benchmark(pathlib.Path(temp_dir), timeout=5)
                bench.active_containers.add("stuck-container")
                bench.cleanup()
                self.assertTrue(bench.failed)
                self.assertIn("stuck-container", bench.active_containers)
                cleanup_errors = (pathlib.Path(temp_dir) / "cleanup-errors.txt").read_text()
                self.assertIn("delete --force timed out", cleanup_errors)
        finally:
            network_streams.subprocess.run = original


class FailureEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = pathlib.Path(self.temp.name)
        self.bench = network_streams.Benchmark(self.output, timeout=5)
        self.endpoint = network_streams.Endpoint(
            "apple-vz", "test-r1", "192.0.2.2", "192.0.2.1", 54321,
        )

    def test_run_records_stderr_before_raising(self):
        command = [sys.executable, "-c", "import sys; print('failure', file=sys.stderr); sys.exit(7)"]
        with self.assertRaisesRegex(RuntimeError, "failed with exit 7"):
            self.bench.run("failed-command", command)
        evidence = (self.output / "failed-command.txt").read_text()
        self.assertIn("failure", evidence)
        self.assertIn("exit_status=7", evidence)

    def test_timeout_keeps_partial_output_and_original_exception(self):
        for stdout, stderr in ((b"partial out", b"partial err\xff"), ("out", "err"), (None, None)):
            with self.subTest(stdout=stdout):
                error = network_streams.subprocess.TimeoutExpired(
                    ["container", "inspect", "test-r1"], 5, output=stdout, stderr=stderr,
                )
                with mock.patch.object(network_streams.subprocess, "run", side_effect=error):
                    with self.assertRaises(network_streams.subprocess.TimeoutExpired) as caught:
                        self.bench.run("timed-out", error.cmd)
                self.assertIs(caught.exception, error)
                evidence = (self.output / "timed-out.txt").read_text()
                self.assertIn("timeout_seconds=5", evidence)
                if stdout is not None:
                    expected = stdout.decode(errors="replace") if isinstance(stdout, bytes) else stdout
                    self.assertIn(expected, evidence)
                if stderr is not None:
                    expected = stderr.decode(errors="replace") if isinstance(stderr, bytes) else stderr
                    self.assertIn(expected, evidence)

    def test_cleanup_failure_keeps_stderr_and_container(self):
        self.bench.active_containers.add("test-r1")
        result = network_streams.subprocess.CompletedProcess([], 1, "", "failed to stop runtime\n")
        with mock.patch.object(network_streams.subprocess, "run", return_value=result) as run:
            self.bench.cleanup()
        self.assertTrue(self.bench.failed)
        self.assertIn("test-r1", self.bench.active_containers)
        evidence = (self.output / "test-r1-delete.txt").read_text()
        self.assertIn("failed to stop runtime", evidence)
        self.assertIn("exit_status=1", evidence)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

    def test_cleanup_timeout_keeps_partial_stderr(self):
        self.bench.active_containers.add("test-r1")
        error = network_streams.subprocess.TimeoutExpired([], 30, stderr=b"waiting for runtime")
        with mock.patch.object(network_streams.subprocess, "run", side_effect=error):
            self.bench.cleanup()
        self.assertTrue(self.bench.failed)
        self.assertIn("waiting for runtime", (self.output / "test-r1-delete.txt").read_text())
        self.assertIn("test-r1", self.bench.active_containers)

    def test_cleanup_launch_error_is_archived(self):
        self.bench.active_containers.add("test-r1")
        with mock.patch.object(network_streams.subprocess, "run", side_effect=FileNotFoundError("container")):
            self.bench.cleanup()
        self.assertTrue(self.bench.failed)
        self.assertIn("launch_error=", (self.output / "test-r1-delete.txt").read_text())
        self.assertIn("could not run", (self.output / "cleanup-errors.txt").read_text())

    def test_successful_cleanup_removes_container_and_keeps_output(self):
        self.bench.active_containers.add("test-r1")
        result = network_streams.subprocess.CompletedProcess([], 0, "test-r1\n", "")
        with mock.patch.object(network_streams.subprocess, "run", return_value=result):
            self.bench.cleanup()
        self.assertFalse(self.bench.failed)
        self.assertFalse(self.bench.active_containers)
        self.assertIn("exit_status=0", (self.output / "test-r1-delete.txt").read_text())
        self.assertFalse((self.output / "cleanup-errors.txt").exists())

    def test_inspect_preserves_the_attachment_that_selected_the_gateway(self):
        payload = '[{"status":{"networks":[{"ipv4Address":"192.0.2.2/24","ipv4Gateway":"192.0.2.1"}]}}]'
        result = network_streams.subprocess.CompletedProcess([], 0, payload, "")
        with mock.patch.object(network_streams.subprocess, "run", return_value=result):
            addresses = network_streams.inspect_endpoint(self.bench, "test-r1")
        self.assertEqual(addresses, ("192.0.2.2", "192.0.2.1"))
        self.assertEqual((self.output / "test-r1-inspect.txt").read_text(), payload)

    def test_failure_capture_continues_after_missing_diagnostic_tool(self):
        calls = []

        def run(label, command, **kwargs):
            calls.append((label, command, kwargs))
            if len(calls) == 1:
                raise FileNotFoundError("container")
            return network_streams.subprocess.CompletedProcess(command, 1, "", "unavailable")

        with mock.patch.object(self.bench, "run", side_effect=run):
            network_streams.capture_guest_network_failure(
                self.bench, self.endpoint, "192.0.2.1", 54322, "warmup",
            )
        self.assertEqual(len(calls), 8)
        self.assertTrue(all(call[2] == {"check": False, "timeout": 10} for call in calls))
        payload = network_streams.json.loads((self.output / "warmup-network.json").read_text())
        self.assertEqual(payload["target_port"], 54322)
        self.assertEqual(payload["endpoint"]["guest_ip"], "192.0.2.2")
        guest = calls[1][1]
        self.assertEqual(guest[-1], "192.0.2.1")
        self.assertIn('ip -4 route get "$1"', guest[5])
        self.assertIn("ip neigh show", guest[5])
        self.assertEqual(calls[4][1], ["/sbin/route", "-n", "get", "192.0.2.2"])
        self.assertIn("-iTCP:54322", calls[6][1])

    def test_transfer_failure_is_not_retried_or_replaced_by_diagnostic_failure(self):
        original = RuntimeError("warmup failed with exit 1")
        with mock.patch.object(self.bench, "run", side_effect=original) as run:
            with mock.patch.object(
                network_streams, "capture_guest_network_failure", side_effect=OSError("diagnostic failed"),
            ) as capture:
                with self.assertRaises(RuntimeError) as caught:
                    network_streams.guest_source(
                        self.bench, self.endpoint, "192.0.2.1", 54322, 8, 2.0, 262144, "warmup",
                    )
        self.assertIs(caught.exception, original)
        run.assert_called_once()
        capture.assert_called_once_with(self.bench, self.endpoint, "192.0.2.1", 54322, "warmup")
        self.assertEqual(self.bench.samples, [])

    def test_successful_transfer_does_not_collect_failure_diagnostics(self):
        result = network_streams.subprocess.CompletedProcess([], 0, '{"bytes": 1024}\n', "")
        with mock.patch.object(self.bench, "run", return_value=result):
            with mock.patch.object(network_streams, "capture_guest_network_failure") as capture:
                measured = network_streams.guest_source(
                    self.bench, self.endpoint, "192.0.2.1", 54322, 8, 2.0, 262144, "warmup",
                )
        self.assertEqual(measured, {"bytes": 1024})
        capture.assert_not_called()

    def test_capture_runs_while_the_host_sink_is_still_listening(self):
        original = RuntimeError("warmup failed")
        observed = []

        def capture(bench, endpoint, host, port, label):
            with network_streams.socket.create_connection((host, port), timeout=2) as connection:
                connection.sendall(network_streams.STREAM_TRAILER_MAGIC + network_streams.struct.pack("!Q", 0))
                observed.append(network_streams.recv_exact(connection, 8))

        with network_streams.SinkServer("127.0.0.1") as sink:
            with mock.patch.object(self.bench, "run", side_effect=original):
                with mock.patch.object(network_streams, "capture_guest_network_failure", side_effect=capture):
                    with self.assertRaises(RuntimeError) as caught:
                        network_streams.guest_source(
                            self.bench, self.endpoint, "127.0.0.1", sink.port, 8, 2.0, 262144, "warmup",
                        )
        self.assertIs(caught.exception, original)
        self.assertEqual(observed, [network_streams.struct.pack("!Q", 0)])


class SummaryTests(unittest.TestCase):
    def test_summary_groups_runtime_direction_and_parallelism(self):
        samples = [
            network_streams.Sample("a", "guest_to_host", 1, 1, 1, 1.0, 1.01, 100.0, 0),
            network_streams.Sample("a", "guest_to_host", 1, 2, 1, 1.0, 1.03, 300.0, 0),
            network_streams.Sample("a", "guest_to_host", 1, 3, 0, 0.0, 0.0, 0.0, 1),
            network_streams.Sample("b", "host_to_guest", 4, 1, 1, 1.0, 1.02, 500.0, 0),
        ]
        rows = network_streams.summarize(samples)
        first = next(row for row in rows if row["runtime"] == "a")
        self.assertEqual(first["samples"], 2)
        self.assertEqual(first["median_mib_per_second"], 200.0)
        self.assertEqual(first["min_mib_per_second"], 100.0)
        self.assertEqual(first["max_mib_per_second"], 300.0)
        self.assertAlmostEqual(first["median_completion_overhead_ms"], 20.0)

    def test_paired_ratios_match_iterations(self):
        samples = [
            network_streams.Sample("a", "guest_to_host", 1, 1, 1, 1.0, 1.0, 100.0, 0),
            network_streams.Sample("b", "guest_to_host", 1, 1, 1, 1.0, 1.0, 150.0, 0),
            network_streams.Sample("a", "guest_to_host", 1, 2, 1, 1.0, 1.0, 200.0, 0),
            network_streams.Sample("b", "guest_to_host", 1, 2, 1, 1.0, 1.0, 100.0, 0),
            network_streams.Sample("b", "guest_to_host", 1, 3, 1, 1.0, 1.0, 900.0, 0),
        ]
        self.assertEqual(
            network_streams.paired_ratios(samples, "a", "b", "guest_to_host", 1),
            [1.5, 0.5],
        )

    def test_percentile_interpolates(self):
        self.assertEqual(network_streams.percentile([10.0, 20.0, 30.0], 0.5), 20.0)
        self.assertEqual(network_streams.percentile([10.0, 20.0], 0.5), 15.0)


class ProtocolTests(unittest.TestCase):
    def test_parallel_source_and_sink_acknowledge_exact_bytes(self):
        with network_streams.SinkServer("127.0.0.1") as sink:
            result = network_streams.run_source(
                "127.0.0.1",
                sink.port,
                streams=2,
                seconds=0.05,
                chunk_bytes=16 * 1024,
            )
        self.assertEqual(result["streams"], 2)
        self.assertGreater(result["bytes"], 0)
        self.assertGreater(result["elapsed_seconds"], 0)
        self.assertGreaterEqual(result["completion_elapsed_seconds"], result["elapsed_seconds"])
        self.assertGreater(result["mib_per_second"], 0)


    def test_embedded_protocol_scripts_compile(self):
        compile(network_streams.GUEST_SINK_SERVER, "<guest-sink>", "exec")
        compile(network_streams.GUEST_SOURCE, "<guest-source>", "exec")

    def test_stream_protocol_does_not_require_half_close(self):
        class NoHalfCloseSocket:
            def shutdown(self, *_args, **_kwargs):
                raise AssertionError("stream protocol must not half-close the connection")

        self.assertFalse("shutdown(socket.SHUT_WR)" in network_streams.GUEST_SOURCE)
        self.assertNotIn("shutdown(socket.SHUT_WR)", pathlib.Path(network_streams.__file__).read_text())

    def test_host_to_guest_uses_published_port(self):
        calls = []
        original = network_streams.run_source

        def fake_run_source(host, port, streams, seconds, chunk_bytes):
            calls.append((host, port, streams, seconds, chunk_bytes))
            return {
                "bytes": 1024,
                "elapsed_seconds": 1.0,
                "completion_elapsed_seconds": 1.0,
                "mib_per_second": 1.0,
                "streams": streams,
            }

        try:
            network_streams.run_source = fake_run_source
            with tempfile.TemporaryDirectory() as temp_dir:
                bench = network_streams.Benchmark(pathlib.Path(temp_dir), timeout=5)
                endpoint = network_streams.Endpoint(
                    "runtime",
                    "container",
                    "192.0.2.2",
                    "192.0.2.1",
                    54321,
                )
                network_streams.run_direction(
                    bench,
                    [endpoint],
                    "host_to_guest",
                    streams=4,
                    seconds=0.1,
                    warmup_seconds=0.01,
                    iterations=1,
                    chunk_bytes=1024,
                )
        finally:
            network_streams.run_source = original

        self.assertEqual(len(calls), 2)
        self.assertTrue(all(host == "127.0.0.1" for host, *_ in calls))
        self.assertTrue(all(port == 54321 for _, port, *_ in calls))

    def test_parse_json_line_uses_last_json_object(self):
        result = network_streams.parse_json_line('noise\n{"bytes": 1}\n')
        self.assertEqual(result, {"bytes": 1})


if __name__ == "__main__":
    unittest.main()
