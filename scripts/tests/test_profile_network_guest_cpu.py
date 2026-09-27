import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "profile_network_guest_cpu.py"
SCRIPTS_DIR = str(SCRIPT.parent)
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)
SPEC = importlib.util.spec_from_file_location("profile_network_guest_cpu", SCRIPT)
assert SPEC and SPEC.loader
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


class ProcParsingTests(unittest.TestCase):
    def test_cpu_delta_reports_busy_percent(self):
        before = "cpu 0 0 0 0 0 0 0 0 0 0\ncpu0 10 0 5 80 5 0 0 0 0 0\n"
        after = "cpu 0 0 0 0 0 0 0 0 0 0\ncpu0 30 0 15 130 5 0 5 0 0 0\n"
        rows = profile.cpu_delta(before, after)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cpu"], "cpu0")
        self.assertEqual(rows[0]["total_ticks"], 85)
        self.assertEqual(rows[0]["busy_ticks"], 35)
        self.assertAlmostEqual(rows[0]["utilization_percent"], 100 * 35 / 85)

    def test_softirq_delta_is_per_cpu(self):
        before = "                    CPU0       CPU1\nNET_TX:          10         20\nNET_RX:          30         40\n"
        after = "                    CPU0       CPU1\nNET_TX:          13         25\nNET_RX:          37         42\n"
        delta = profile.softirq_delta(before, after)
        self.assertEqual(delta["NET_TX"], {"per_cpu": [3, 5], "total": 8})
        self.assertEqual(delta["NET_RX"], {"per_cpu": [7, 2], "total": 9})

    def test_softnet_delta_decodes_hex_counters(self):
        before = "0000000a 00000001 00000002 00000000\n"
        after = "00000010 00000003 00000005 00000000\n"
        self.assertEqual(
            profile.softnet_delta(before, after),
            [{"cpu": 0, "processed": 6, "dropped": 2, "time_squeeze": 3}],
        )

    def test_interrupt_delta_prioritizes_eth0_device(self):
        before = "           CPU0       CPU1\n 12:         10          0 GICv3 12 Level virtio0\n 13:          1          1 GICv3 13 Level timer\n"
        after = "           CPU0       CPU1\n 12:         20          5 GICv3 12 Level virtio0\n 13:          3          2 GICv3 13 Level timer\n"
        rows = profile.interrupt_delta(before, after, "/sys/devices/platform/virtio0")
        self.assertEqual(rows[0]["irq"], "12")
        self.assertEqual(rows[0]["per_cpu"], [10, 5])
        self.assertTrue(rows[0]["matches_eth0_device"])

    def test_enabled_virtio_feature_bits_decodes_sysfs_order(self):
        self.assertEqual(profile.enabled_virtio_feature_bits("101001\n"), [0, 2, 5])
        self.assertEqual(profile.enabled_virtio_feature_bits("ERROR: missing"), [])

    def test_guest_snapshot_script_compiles(self):
        compile(profile.GUEST_SNAPSHOT, "<guest-snapshot>", "exec")


if __name__ == "__main__":
    unittest.main()
