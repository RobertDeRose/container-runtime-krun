import argparse
import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "benchmark_network_network_scaling.py"
SCRIPTS_DIR = str(SCRIPT.parent)
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)
SPEC = importlib.util.spec_from_file_location("benchmark_network_network_scaling", SCRIPT)
assert SPEC and SPEC.loader
network_scaling = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = network_scaling
SPEC.loader.exec_module(network_scaling)


class StreamSplitTests(unittest.TestCase):
    def test_split_streams_evenly(self):
        self.assertEqual(network_scaling.split_streams(8), 4)
        self.assertEqual(network_scaling.split_streams(2), 1)

    def test_split_streams_rejects_odd_or_too_small(self):
        for value in (0, 1, 3, 7):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    network_scaling.split_streams(value)


class AggregateTests(unittest.TestCase):
    def test_aggregate_results_sums_bytes_over_shared_duration(self):
        result = network_scaling.aggregate_results(
            [
                {
                    "bytes": 100 * 1024 * 1024,
                    "elapsed_seconds": 2.0,
                    "completion_elapsed_seconds": 2.1,
                },
                {
                    "bytes": 200 * 1024 * 1024,
                    "elapsed_seconds": 2.0,
                    "completion_elapsed_seconds": 2.2,
                },
            ],
            total_streams=8,
        )
        self.assertEqual(result["bytes"], 300 * 1024 * 1024)
        self.assertEqual(result["streams"], 8)
        self.assertEqual(result["elapsed_seconds"], 2.0)
        self.assertEqual(result["completion_elapsed_seconds"], 2.2)
        self.assertEqual(result["mib_per_second"], 150.0)

    def test_aggregate_results_requires_input(self):
        with self.assertRaises(ValueError):
            network_scaling.aggregate_results([], total_streams=8)


if __name__ == "__main__":
    unittest.main()
