import argparse
import importlib.util
import pathlib
import sys
import tempfile
import unittest


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
