import argparse
import importlib.util
import pathlib
import sys
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

    def test_parse_json_line_uses_last_json_object(self):
        result = network_streams.parse_json_line('noise\n{"bytes": 1}\n')
        self.assertEqual(result, {"bytes": 1})


if __name__ == "__main__":
    unittest.main()
