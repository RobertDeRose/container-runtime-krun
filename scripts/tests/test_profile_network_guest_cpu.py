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


class TxDatapathTests(unittest.TestCase):
    def test_parse_krun_helper_processes_ignores_sudo_wrapper(self):
        config = "/Users/test/Library/Application Support/krun/containers/abc/krun-vmm.json"
        helper = (
            "/Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun/bin/"
            "container-krun-vmm-helper"
        )
        text = (
            f"  41 /usr/bin/sudo -n -- {helper} {config}\n"
            f"  42 {helper} {config}\n"
            "  43 python3 unrelated.py\n"
        )
        helpers = profile.parse_krun_helper_processes(text)
        self.assertEqual(set(helpers), {42})
        self.assertEqual(helpers[42].config_path, pathlib.Path(config))
        self.assertEqual(helpers[42].log_path.name, "krun-vmm.log")
        self.assertEqual(helpers[42].log_path.parent, helpers[42].config_path.parent)

    def test_snapshot_tx_datapath_rejects_missing_handoff_fields(self):
        original = profile.signal_tx_datapath
        profile.signal_tx_datapath = lambda *_args, **_kwargs: {"network_index": 0}
        try:
            helper = profile.KrunHelperProcess(
                42, pathlib.Path("/tmp/krun-vmm.json"), pathlib.Path("/tmp/krun-vmm.log")
            )
            with self.assertRaisesRegex(RuntimeError, "lacks TX handoff instrumentation fields"):
                profile.snapshot_tx_datapath(helper)
        finally:
            profile.signal_tx_datapath = original

    def test_snapshot_tx_datapath_accepts_handoff_fields(self):
        payload = {"network_index": 0, **{key: 0 for key in profile.TX_HANDOFF_REQUIRED_FIELDS}}
        original = profile.signal_tx_datapath
        profile.signal_tx_datapath = lambda *_args, **_kwargs: payload
        try:
            helper = profile.KrunHelperProcess(
                42, pathlib.Path("/tmp/krun-vmm.json"), pathlib.Path("/tmp/krun-vmm.log")
            )
            self.assertEqual(profile.snapshot_tx_datapath(helper), payload)
        finally:
            profile.signal_tx_datapath = original

    def test_tx_datapath_derived_reports_requested_ratios(self):
        counters = {
            "queue_notify_writes": 100,
            "eventfd_wakeups": 80,
            "eventfd_values": 100,
            "drain_passes": 50,
            "empty_drain_passes": 5,
            "frames": 400,
            "bytes": 2 * 1024**3,
            "descriptor_chains": 400,
            "descriptors": 800,
            "write_frame_calls": 400,
            "flush_calls": 20,
            "frames_between_flushes": 400,
            "bytes_between_flushes": 2 * 1024**3,
            "timing_sampled_frames": 10,
            "descriptor_parse_sample_ns": 1_000,
            "guest_copy_sample_ns": 3_000,
            "backend_write_sample_ns": 6_000,
            "timing_sampled_flushes": 4,
            "flush_sample_ns": 800,
            "timing_sampled_drain_cycles": 5,
            "timing_sampled_drain_frames": 40,
            "drain_cycle_sample_ns": 20_000,
            "tx_queue_disable_sample_ns": 500,
            "tx_queue_enable_sample_ns": 1_000,
            "add_used_sample_ns": 2_000,
            "timing_sampled_notification_checks": 4,
            "notification_check_sample_ns": 800,
            "timing_sampled_irq_signals": 2,
            "irq_signal_sample_ns": 600,
            "notify_to_eventfd_samples": 4,
            "notify_to_eventfd_sample_ns": 4_000,
            "notify_to_eventfd_max_ns": 1_500,
            "eventfd_write_samples": 4,
            "eventfd_write_sample_ns": 400,
            "eventfd_write_max_ns": 150,
            "notify_while_worker_waiting_samples": 3,
            "notify_while_worker_busy_samples": 1,
            "notify_to_kqueue_ready_samples": 4,
            "notify_to_kqueue_ready_sample_ns": 3_200,
            "notify_to_kqueue_ready_max_ns": 1_100,
            "kqueue_ready_to_eventfd_samples": 4,
            "kqueue_ready_to_eventfd_sample_ns": 800,
            "kqueue_ready_to_eventfd_max_ns": 300,
            "irq_to_next_notify_samples": 2,
            "irq_to_next_notify_sample_ns": 6_000,
            "irq_to_next_notify_max_ns": 4_000,
        }
        result = {"elapsed_seconds": 20.0}
        delta = {
            "interrupts": [
                {"total": 25, "matches_eth0_device": True},
                {"total": 99, "matches_eth0_device": False},
            ]
        }
        derived = profile.tx_datapath_derived(counters, result, delta)
        self.assertEqual(derived["tx_kicks_per_second"], 5.0)
        self.assertEqual(derived["tx_kicks_per_gib"], 50.0)
        self.assertEqual(derived["eventfd_wakeups_per_second"], 4.0)
        self.assertEqual(derived["frames_per_worker_wakeup"], 5.0)
        self.assertEqual(derived["descriptor_chains_per_wakeup"], 5.0)
        self.assertEqual(derived["descriptors_per_frame"], 2.0)
        self.assertEqual(derived["backend_calls_per_frame"], 1.0)
        self.assertEqual(derived["flushes_per_gib"], 10.0)
        self.assertEqual(derived["guest_irq_per_tx_kick"], 0.25)
        self.assertEqual(derived["empty_drain_fraction"], 0.1)
        self.assertEqual(derived["descriptor_parse_ns_per_sampled_frame"], 100.0)
        self.assertEqual(derived["guest_copy_ns_per_sampled_frame"], 300.0)
        self.assertEqual(derived["backend_write_ns_per_sampled_frame"], 600.0)
        self.assertEqual(derived["descriptor_parse_sample_percent"], 10.0)
        self.assertEqual(derived["guest_copy_sample_percent"], 30.0)
        self.assertEqual(derived["backend_write_sample_percent"], 60.0)
        self.assertEqual(derived["flush_ns_per_sampled_call"], 200.0)
        self.assertEqual(derived["drain_cycle_ns_per_sampled_cycle"], 4_000.0)
        self.assertEqual(derived["frames_per_sampled_drain_cycle"], 8.0)
        self.assertEqual(derived["drain_cycle_ns_per_sampled_frame"], 500.0)
        self.assertEqual(derived["tx_queue_disable_ns_per_sampled_cycle"], 100.0)
        self.assertEqual(derived["tx_queue_enable_ns_per_sampled_cycle"], 200.0)
        self.assertEqual(derived["add_used_ns_per_sampled_frame"], 200.0)
        self.assertEqual(derived["notification_check_ns_per_sampled_call"], 200.0)
        self.assertEqual(derived["irq_signal_ns_per_sampled_call"], 300.0)
        self.assertEqual(derived["notify_to_eventfd_ns_per_sample"], 1_000.0)
        self.assertEqual(derived["notify_to_eventfd_max_ns"], 1_500.0)
        self.assertEqual(derived["eventfd_write_ns_per_sample"], 100.0)
        self.assertEqual(derived["eventfd_write_max_ns"], 150.0)
        self.assertEqual(
            derived["notify_to_worker_minus_eventfd_write_ns_per_sample"], 900.0
        )
        self.assertEqual(derived["notify_worker_waiting_fraction"], 0.75)
        self.assertEqual(derived["notify_to_kqueue_ready_ns_per_sample"], 800.0)
        self.assertEqual(derived["notify_to_kqueue_ready_max_ns"], 1_100.0)
        self.assertEqual(derived["kqueue_ready_to_eventfd_ns_per_sample"], 200.0)
        self.assertEqual(derived["kqueue_ready_to_eventfd_max_ns"], 300.0)
        self.assertEqual(derived["irq_to_next_notify_ns_per_sample"], 3_000.0)
        self.assertEqual(derived["irq_to_next_notify_max_ns"], 4_000.0)
        self.assertEqual(derived["estimated_tx_drain_active_fraction"], 0.00001)

    def test_tx_datapath_derived_handles_zero_denominators(self):
        derived = profile.tx_datapath_derived({}, {"elapsed_seconds": 0.0}, {"interrupts": []})
        self.assertIsNone(derived["tx_kicks_per_second"])
        self.assertIsNone(derived["frames_per_worker_wakeup"])
        self.assertIsNone(derived["descriptors_per_frame"])
        self.assertIsNone(derived["guest_irq_per_tx_kick"])
        self.assertIsNone(derived["descriptor_parse_ns_per_sampled_frame"])
        self.assertIsNone(derived["backend_write_sample_percent"])
        self.assertIsNone(derived["flush_ns_per_sampled_call"])
        self.assertIsNone(derived["drain_cycle_ns_per_sampled_frame"])
        self.assertIsNone(derived["add_used_ns_per_sampled_frame"])
        self.assertIsNone(derived["notification_check_ns_per_sampled_call"])
        self.assertIsNone(derived["irq_signal_ns_per_sampled_call"])
        self.assertIsNone(derived["notify_to_eventfd_ns_per_sample"])
        self.assertIsNone(derived["eventfd_write_ns_per_sample"])
        self.assertIsNone(derived["notify_to_worker_minus_eventfd_write_ns_per_sample"])
        self.assertIsNone(derived["notify_worker_waiting_fraction"])
        self.assertIsNone(derived["notify_to_kqueue_ready_ns_per_sample"])
        self.assertIsNone(derived["kqueue_ready_to_eventfd_ns_per_sample"])
        self.assertIsNone(derived["irq_to_next_notify_ns_per_sample"])
        self.assertIsNone(derived["estimated_tx_drain_active_fraction"])


if __name__ == "__main__":
    unittest.main()
