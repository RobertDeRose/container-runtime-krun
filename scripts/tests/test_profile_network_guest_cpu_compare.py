import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "profile_network_guest_cpu_compare.py"
SCRIPTS_DIR = str(SCRIPT.parent)
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)
SPEC = importlib.util.spec_from_file_location("profile_network_guest_cpu_compare", SCRIPT)
assert SPEC and SPEC.loader
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


class SummaryTests(unittest.TestCase):
    def test_summary_reports_queue_and_irq_concentration(self):
        rows = [
            {
                "iteration": 1,
                "throughput_mib_per_second": 4000.0,
                "delta": {
                    "cpu": [
                        {"cpu": "cpu0", "utilization_percent": 50.0},
                        {"cpu": "cpu1", "utilization_percent": 20.0},
                    ],
                    "softirqs": {"NET_RX": {"per_cpu": [90, 10], "total": 100}},
                    "softnet": [
                        {"cpu": 0, "processed": 80, "dropped": 0, "time_squeeze": 0},
                        {"cpu": 1, "processed": 20, "dropped": 0, "time_squeeze": 0},
                    ],
                    "interrupts": [
                        {
                            "irq": "7",
                            "per_cpu": [100, 0],
                            "total": 100,
                            "matches_eth0_device": True,
                        }
                    ],
                    "net_queues": ["rx-0", "rx-1", "tx-0", "tx-1"],
                },
            },
            {
                "iteration": 2,
                "throughput_mib_per_second": 4200.0,
                "delta": {
                    "cpu": [
                        {"cpu": "cpu0", "utilization_percent": 40.0},
                        {"cpu": "cpu1", "utilization_percent": 30.0},
                    ],
                    "softirqs": {"NET_RX": {"per_cpu": [80, 20], "total": 100}},
                    "softnet": [
                        {"cpu": 0, "processed": 70, "dropped": 0, "time_squeeze": 0},
                        {"cpu": 1, "processed": 30, "dropped": 0, "time_squeeze": 0},
                    ],
                    "interrupts": [
                        {
                            "irq": "7",
                            "per_cpu": [90, 10],
                            "total": 100,
                            "matches_eth0_device": True,
                        }
                    ],
                    "net_queues": ["rx-0", "rx-1", "tx-0", "tx-1"],
                },
            },
        ]
        summary = profile.summarize_profile(rows)
        self.assertEqual(summary["median_mib_per_second"], 4100.0)
        self.assertEqual(summary["rx_queue_count"], 2)
        self.assertEqual(summary["tx_queue_count"], 2)
        self.assertEqual(summary["busiest_cpu"], "cpu0")
        self.assertEqual(summary["busiest_cpu_median_utilization_percent"], 45.0)
        self.assertAlmostEqual(summary["eth_irq_dominant_cpu_share"], 0.95)
        self.assertAlmostEqual(summary["net_rx_dominant_cpu_share"], 0.85)
        self.assertAlmostEqual(summary["softnet_dominant_cpu_share"], 0.75)


if __name__ == "__main__":
    unittest.main()
