import argparse
import importlib.util
import unittest
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "benchmark_vmnet_helper_control.py"
SPEC = importlib.util.spec_from_file_location("benchmark_vmnet_helper_control", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VmnetHelperControlTests(unittest.TestCase):
    def test_parse_streams(self):
        self.assertEqual(MODULE.parse_streams("1,4,8"), [1, 4, 8])

    def test_parse_streams_rejects_nonpositive(self):
        with self.assertRaises(argparse.ArgumentTypeError):
            MODULE.parse_streams("1,0,8")

    def test_summarize_groups_stream_counts(self):
        samples = [
            MODULE.Sample(1, 1, 8.0, 1.0),
            MODULE.Sample(1, 2, 16.0, 2.0),
            MODULE.Sample(4, 1, 80.0, 10.0),
        ]
        rows = MODULE.summarize(samples)
        self.assertEqual([row["streams"] for row in rows], [1, 4])
        self.assertEqual(rows[0]["median_mib_per_second"], 1.5)
        self.assertEqual(rows[1]["median_mib_per_second"], 10.0)


if __name__ == "__main__":
    unittest.main()
