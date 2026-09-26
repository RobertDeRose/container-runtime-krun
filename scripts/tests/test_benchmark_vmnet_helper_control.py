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


    def test_prepare_krunkit_builds_without_make_or_install_name_tool(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "runtime"
            checkout = Path(tmp) / "krunkit"
            prefix = Path(tmp) / "prefix"
            libkrun = root / ".build-deps/libkrun/target/release" / MODULE.LIBKRUN_DYLIB
            libkrun.parent.mkdir(parents=True)
            libkrun.write_bytes(b"libkrun")
            (checkout / "target/release").mkdir(parents=True)
            (checkout / "edk2").mkdir()
            source_binary = checkout / "target/release/krunkit"
            source_binary.write_bytes(b"krunkit")
            (checkout / "edk2/KRUN_EFI.silent.fd").write_bytes(b"firmware")

            calls = []

            def fake_run(argv, **kwargs):
                calls.append((argv, kwargs))
                stdout = "path @executable_path/../lib (offset 12)\n" if argv[:2] == ["otool", "-l"] else ""
                return mock.Mock(returncode=0, stdout=stdout, stderr="")

            with mock.patch.object(MODULE, "run", side_effect=fake_run), mock.patch.object(
                MODULE.subprocess, "run", return_value=mock.Mock(returncode=0)
            ):
                binary = MODULE.prepare_krunkit(root, checkout, prefix, 30)

            cargo = next(call for call in calls if call[0][:2] == ["cargo", "build"])
            self.assertEqual(cargo[0], ["cargo", "build", "--release"])
            self.assertEqual(cargo[1]["env"]["PREFIX"], str(prefix))
            self.assertIn("@executable_path/../lib", cargo[1]["env"]["RUSTFLAGS"])
            self.assertEqual(binary.read_bytes(), b"krunkit")
            self.assertEqual((prefix / "share/krunkit/KRUN_EFI.silent.fd").read_bytes(), b"firmware")

    def test_control_does_not_invoke_krunkit_make_install(self):
        source = MODULE_PATH.read_text()
        self.assertNotIn('["make", "install"', source)
        self.assertNotIn('"install_name_tool"', source)

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
