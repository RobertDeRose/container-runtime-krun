import argparse
import importlib.util
import unittest
from unittest import mock
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "benchmark_vmnet_helper_control.py"
sys.path.insert(0, str(MODULE_PATH.parent))
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

    def test_control_does_not_require_host_iperf3(self):
        source = MODULE_PATH.read_text()
        self.assertNotIn('"iperf3"', source)
        self.assertIn("streams_bench.GUEST_SOURCE", source)

    def test_control_uses_native_tools_for_guest_artifacts(self):
        source = MODULE_PATH.read_text()
        self.assertNotIn('"mkisofs"', source)
        self.assertNotIn('"qemu-img"', source)
        self.assertNotIn('"bsdtar"', source)
        self.assertIn('"hdiutil"', source)

    def test_create_cidata_iso_uses_cidata_volume_label(self):
        class Store:
            @staticmethod
            def vm_path(_name, filename):
                return self.tmp / filename

        class Cidata:
            store = Store()

            @staticmethod
            def create_meta_data(_vm):
                return {"instance-id": "test"}

            @staticmethod
            def create_user_data(_vm):
                return {"users": []}

            @staticmethod
            def create_network_config(_vm):
                return {"version": 2}

        import tempfile
        from types import SimpleNamespace

        with tempfile.TemporaryDirectory() as tmp:
            self.tmp = Path(tmp)
            vm = SimpleNamespace(vm_name="control")
            with mock.patch.object(MODULE, "run") as run:
                result = MODULE.create_cidata_iso(vm, Cidata, 30)
            argv = run.call_args.args[0]
            self.assertEqual(argv[0:2], ["hdiutil", "makehybrid"])
            self.assertIn("-iso", argv)
            self.assertIn("-joliet", argv)
            label = argv.index("-default-volume-name")
            self.assertEqual(argv[label + 1], "cidata")
            self.assertEqual(result, str(self.tmp / "cidata.iso"))

    def test_mark_root_disk_qcow2_changes_only_first_disk(self):
        command = [
            "krunkit",
            "--device=virtio-blk,path=/tmp/root.qcow2",
            "--device=virtio-blk,path=/tmp/cidata.iso",
        ]
        self.assertEqual(
            MODULE.mark_root_disk_qcow2(command),
            [
                "krunkit",
                "--device=virtio-blk,path=/tmp/root.qcow2,format=qcow2",
                "--device=virtio-blk,path=/tmp/cidata.iso",
            ],
        )


if __name__ == "__main__":
    unittest.main()
