import contextlib
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


SCRIPTS = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
import profile_network_streams as profile


@unittest.skipUnless(sys.platform == "darwin", "requires macOS caffeinate and system bash")
class TaskWrapperTests(unittest.TestCase):
    def test_boolean_flag_and_empty_array_work_with_system_bash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            shim = root / "python3"
            shim.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE_ARGS"\n')
            shim.chmod(0o755)
            capture = root / "args.txt"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "CAPTURE_ARGS": str(capture), "MISE_PROJECT_ROOT": str(SCRIPTS.parent)}
            for key, value in {
                "runtime": "container-runtime-krun", "network": "default", "image": "fixture:image",
                "streams": "8", "seconds": "30", "warmup_seconds": "3", "sample_delay": "2",
                "sample_seconds": "20", "sample_interval_ms": "10", "chunk_kib": "256",
                "timeout": "180", "result_root": directory,
            }.items():
                env[f"usage_{key}"] = value
            for enabled in (None, "false", "true"):
                with self.subTest(enabled=enabled):
                    env.pop("usage_tx_attribution", None)
                    if enabled is not None:
                        env["usage_tx_attribution"] = enabled
                    result = subprocess.run(["/bin/bash", str(SCRIPTS.parent / ".mise/tasks/profile/network-streams")],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual("--tx-attribution" in capture.read_text().splitlines(), enabled == "true")


class InstalledProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.output = self.root / "evidence"
        self.output.mkdir()
        self.cli = self.root / "bin/container"
        self.cli.parent.mkdir()
        self.cli.write_text('#!/bin/sh\necho "container CLI version fixture"\n')
        self.cli.chmod(0o755)
        self.trusted = self.root / "protected"
        self.library = self.trusted / "lib/libkrun.dylib"
        self.helper = self.trusted / "bin/container-krun-vmm-helper"
        runtime = self.root / "libexec/container-plugins/container-runtime-krun/bin/container-runtime-krun"
        for path in (self.library, self.helper, runtime):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(path.name.encode())
        self.manifest = self.trusted / "lib/libkrun.provenance"
        values = {
            "commit": "a" * 40, "source_build_sha256": "b" * 64,
            "sha256": hashlib.sha256(self.library.read_bytes()).hexdigest(),
            "helper_sha256": hashlib.sha256(self.helper.read_bytes()).hexdigest(),
            "runtime_sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
            "source_dirty": "false", "backend": "libkrun-vmnet-shared", "features": "BLK=1 NET=1",
        }
        self.manifest.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in (("TRUSTED", self.trusted), ("LIBRARY", self.library), ("HELPER", self.helper)):
            self.stack.enter_context(mock.patch.object(profile.native_validation, name, value))
        self.stack.enter_context(mock.patch.dict(profile.os.environ, {"INSTALL_ROOT": str(self.root)}))
        self.stack.enter_context(mock.patch.object(profile.shutil, "which", return_value=str(self.cli)))

    def test_verified_hashes_and_exact_manifest_are_saved(self):
        evidence = profile.capture_installed_provenance(self.output, "before")
        self.assertTrue(evidence["verified"])
        self.assertEqual(evidence["commit"], "a" * 40)
        self.assertEqual(len(evidence["files"]), 3)
        self.assertEqual(evidence["container_cli"]["version"], "container CLI version fixture")
        self.assertEqual(evidence["container_cli"]["sha256"], hashlib.sha256(self.cli.read_bytes()).hexdigest())
        self.assertEqual(json.loads((self.output / "installed-before.json").read_text()), evidence)
        self.assertEqual((self.output / "installed-before.provenance").read_bytes(), self.manifest.read_bytes())
        self.assertEqual(evidence, profile.capture_installed_provenance(self.output, "after"))

    def test_mismatch_is_archived_and_rejected(self):
        self.helper.write_bytes(b"replacement")
        with self.assertRaisesRegex(RuntimeError, "hash does not match"):
            profile.capture_installed_provenance(self.output, "before")
        evidence = json.loads((self.output / "installed-before.json").read_text())
        self.assertFalse(evidence["verified"])
        self.assertNotEqual(evidence["files"][-1]["sha256"], evidence["files"][-1]["recorded_sha256"])

    def test_dirty_and_duplicate_manifests_are_not_accepted(self):
        original = self.manifest.read_text()
        for text in (original.replace("source_dirty=false", "source_dirty=true"),
                     original + "commit=" + "a" * 40 + "\n"):
            self.manifest.write_text(text)
            with self.assertRaises(RuntimeError):
                profile.capture_installed_provenance(self.output, "before")

    def test_cli_change_is_visible_and_missing_native_plugin_fails(self):
        before = profile.capture_installed_provenance(self.output, "before")
        self.cli.write_text('#!/bin/sh\necho "container CLI version replacement"\n')
        self.assertNotEqual(before, profile.capture_installed_provenance(self.output, "after"))
        (self.root / "libexec/container-plugins/container-runtime-krun/bin/container-runtime-krun").unlink()
        with self.assertRaisesRegex(RuntimeError, "select the matching container CLI"):
            profile.capture_installed_provenance(self.output, "after")
        self.assertFalse(json.loads((self.output / "installed-after.json").read_text())["verified"])

    def test_manifest_changes_are_visible_even_with_same_file_hashes(self):
        before = profile.capture_installed_provenance(self.output, "before")
        self.manifest.write_text(self.manifest.read_text() + "repository=changed\n")
        self.assertNotEqual(before, profile.capture_installed_provenance(self.output, "after"))


class AttributionContextTests(unittest.TestCase):
    def collect(self, primary=False, snapshot_failure=False, reset_failure=False, cpu_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            config = output / "source-config.json"
            config.write_text("{}")
            log = output / "source-vmm.log"
            log.write_text("helper log\n")
            helper = profile.guest_profile.KrunHelperProcess(22, config, log)
            reader = mock.Mock()
            reader.executable.return_value = str(profile.native_validation.HELPER)
            def cpu_snapshot(pid):
                return {"pid": pid, "observed_ns": time.monotonic_ns(), "threads": [{
                    "handle": 1, "name": "worker", "user_ns": 0, "system_ns": 0, "run_state": 3,
                }]}
            reader.snapshot.side_effect = OSError("denied") if cpu_failure else cpu_snapshot
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(profile, "ThreadReader", return_value=reader))
                stack.enter_context(mock.patch.object(profile.guest_profile, "krun_helper_processes",
                                                      return_value={22: helper}))
                reset = stack.enter_context(mock.patch.object(profile.guest_profile, "reset_tx_datapath",
                    side_effect=RuntimeError("reset failure") if reset_failure else None))
                snapshot = stack.enter_context(mock.patch.object(profile.guest_profile, "snapshot_tx_datapath",
                    return_value={"frames": 12},
                    side_effect=RuntimeError("snapshot failure") if snapshot_failure else None))
                error = None
                try:
                    with profile.tx_attribution(output, 22, 1):
                        if primary:
                            raise RuntimeError("primary sample failure")
                except Exception as failure:
                    error = str(failure)
            evidence = json.loads((output / "tx-attribution.json").read_text())
            self.assertEqual((output / "krun-vmm.log").read_text(), "helper log\n")
            self.assertEqual((output / "krun-vmm.json").read_text(), "{}")
            self.assertTrue((output / "host-activity.json").exists())
            if not reset_failure and not cpu_failure:
                reset.assert_called_once_with(helper)
                snapshot.assert_called_once_with(helper)
                for key in ("reset_requested_ns", "reset_ack_ns", "snapshot_requested_ns"):
                    self.assertGreater(evidence[key], 0)
            else:
                snapshot.assert_not_called()
            return error, evidence

    def test_capture_uses_existing_counters_and_cpu_evidence(self):
        error, evidence = self.collect()
        self.assertIsNone(error)
        self.assertEqual(evidence["counters"], {"frames": 12})
        self.assertFalse(evidence["errors"])

    def test_cleanup_failure_does_not_replace_sample_error(self):
        error, evidence = self.collect(primary=True, snapshot_failure=True)
        self.assertEqual(error, "primary sample failure")
        self.assertIn("snapshot failure", evidence["errors"][0])
        self.assertIn("primary sample failure", evidence["primary_error"])

    def test_incomplete_snapshot_fails_instead_of_empty_pass(self):
        error, evidence = self.collect(snapshot_failure=True)
        self.assertIn("incomplete TX attribution", error)
        self.assertNotIn("counters", evidence)

    def test_reset_failure_is_preserved_and_partial_cpu_is_saved(self):
        error, evidence = self.collect(reset_failure=True)
        self.assertEqual(error, "reset failure")
        self.assertIn("reset failure", evidence["primary_error"])

    def test_libproc_preflight_failure_is_preserved(self):
        error, evidence = self.collect(cpu_failure=True)
        self.assertIn("denied", error)
        self.assertTrue(evidence["errors"])


if __name__ == "__main__":
    unittest.main()
