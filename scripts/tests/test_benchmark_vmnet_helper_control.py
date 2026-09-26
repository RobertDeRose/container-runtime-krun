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
            (checkout / "src").mkdir()
            (checkout / "src/context.rs").write_text(MODULE.KRUNKIT_GPU_BLOCK)
            source_binary = checkout / "target/release/krunkit"
            source_binary.write_bytes(b"krunkit")
            (checkout / "edk2/KRUN_EFI.silent.fd").write_bytes(b"firmware")
            (checkout / "krunkit.entitlements").write_text("<plist/>")

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
            self.assertNotIn("RUSTFLAGS", cargo[1]["env"])
            self.assertEqual(binary.read_bytes(), b"krunkit")
            self.assertEqual((prefix / "share/krunkit/KRUN_EFI.silent.fd").read_bytes(), b"firmware")
            codesign = next(call for call in calls if call[0][0] == "codesign")
            self.assertEqual(
                codesign[0],
                [
                    "codesign",
                    "--entitlements",
                    str(checkout / "krunkit.entitlements"),
                    "--force",
                    "-s",
                    "-",
                    str(binary),
                ],
            )


    def test_prepare_krunkit_resigns_cached_binary(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "runtime"
            checkout = Path(tmp) / "krunkit"
            prefix = Path(tmp) / "prefix"
            libkrun = root / ".build-deps/libkrun/target/release" / MODULE.LIBKRUN_DYLIB
            libkrun.parent.mkdir(parents=True)
            libkrun.write_bytes(b"libkrun")
            (checkout / "krunkit.entitlements").parent.mkdir(parents=True)
            (checkout / "krunkit.entitlements").write_text("<plist/>")
            binary = prefix / "bin/krunkit"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"cached")
            (prefix / ".krunkit-control-stamp").write_text(
                f"{MODULE.KRUNKIT_COMMIT} {MODULE.sha256(libkrun)} {MODULE.KRUNKIT_CONTROL_PATCH}\n"
            )

            calls = []

            def fake_run(argv, **kwargs):
                calls.append(argv)
                return mock.Mock(returncode=0, stdout="", stderr="")

            with mock.patch.object(MODULE, "run", side_effect=fake_run):
                result = MODULE.prepare_krunkit(root, checkout, prefix, 30)

            self.assertEqual(result, binary)
            self.assertFalse(any(argv[:2] == ["cargo", "build"] for argv in calls))
            self.assertTrue(any(argv[0] == "codesign" for argv in calls))

    def test_control_does_not_invoke_krunkit_make_install(self):
        source = MODULE_PATH.read_text()
        self.assertNotIn('["make", "install"', source)
        self.assertNotIn('"install_name_tool"', source)



    def test_control_starts_krunkit_with_control_dylib_path(self):
        source = MODULE_PATH.read_text()
        self.assertIn('os.environ["DYLD_LIBRARY_PATH"]', source)
        self.assertIn('str(control_prefix / "lib")', source)

    def test_wait_for_ssh_retries_until_ipv4_is_reachable(self):
        vm = mock.Mock()
        vm.vm_name = "control"
        vm.fqdn.return_value = "control-vmnet-helper.local"
        connection = mock.MagicMock()

        with mock.patch.object(
            MODULE.socket,
            "gethostbyname",
            side_effect=[MODULE.socket.gaierror("not ready"), "192.168.64.2"],
        ) as resolve, mock.patch.object(
            MODULE.socket, "create_connection", return_value=connection
        ) as connect, mock.patch.object(MODULE.time, "sleep"):
            address = MODULE.wait_for_ssh(vm, 30)

        self.assertEqual(address, "192.168.64.2")
        self.assertEqual(resolve.call_count, 2)
        connect.assert_called_once_with(("192.168.64.2", 22), timeout=2)
        vm.check_running.assert_called_once_with()

    def test_ssh_pins_control_ipv4(self):
        with mock.patch.object(
            MODULE, "run", return_value=mock.Mock(returncode=0, stdout="", stderr="")
        ) as run:
            MODULE.ssh("control", Path("ssh.config"), "192.168.64.2", ["true"], 30)

        self.assertEqual(
            run.call_args.args[0],
            [
                "ssh",
                "-4",
                "-F",
                "ssh.config",
                "-o",
                "HostName=192.168.64.2",
                "control",
                "true",
            ],
        )

    def test_patch_krunkit_headless_removes_default_gpu_setup(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            checkout = Path(tmp)
            context = checkout / "src/context.rs"
            context.parent.mkdir(parents=True)
            original = f"before\n{MODULE.KRUNKIT_GPU_BLOCK}after\n"
            context.write_text(original)

            path, source = MODULE.patch_krunkit_headless(checkout)

            self.assertEqual(path, context)
            self.assertEqual(source, original)
            patched = context.read_text()
            self.assertNotIn(MODULE.KRUNKIT_GPU_BLOCK, patched)
            self.assertIn(MODULE.KRUNKIT_HEADLESS_BLOCK, patched)

    def test_wait_for_ssh_surfaces_krunkit_log_on_vm_exit(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            vm_dir = home / ".vmnet-helper/vms/control"
            vm_dir.mkdir(parents=True)
            (vm_dir / "krunkit.command").write_text("krunkit --device test\n")
            (vm_dir / "krunkit.log").write_text("fatal control failure\n")

            vm = mock.Mock()
            vm.vm_name = "control"
            vm.check_running.side_effect = RuntimeError("Virtual machine terminated (exitcode -6)")
            with mock.patch.object(MODULE.Path, "home", return_value=home), mock.patch.object(
                MODULE.socket, "gethostbyname", return_value="192.168.64.2"
            ), mock.patch.object(
                MODULE.socket, "create_connection", side_effect=OSError("not ready")
            ), mock.patch.object(MODULE.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "fatal control failure") as caught:
                    MODULE.wait_for_ssh(vm, 30)

            self.assertIn("krunkit --device test", str(caught.exception))
            self.assertIn("exitcode -6", str(caught.exception))

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
