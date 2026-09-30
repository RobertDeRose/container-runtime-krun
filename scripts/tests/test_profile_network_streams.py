import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPTS = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "profile_network_streams.py"
SPEC = importlib.util.spec_from_file_location("profile_network_streams", SCRIPT)
assert SPEC and SPEC.loader
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


class ProfilerCommandTests(unittest.TestCase):
    def test_privileged_argv_uses_noninteractive_sudo_after_authorization(self):
        self.assertEqual(
            profile.privileged_argv(["/usr/bin/sample", "123", "20"]),
            ["/usr/bin/sudo", "-n", "--", "/usr/bin/sample", "123", "20"],
        )

    def test_thread_snapshot_argv_uses_supported_macos_ps_fields(self):
        argv = profile.thread_snapshot_argv(123)
        self.assertEqual(argv[:4], ["/bin/ps", "-M", "-p", "123"])
        self.assertNotIn("tid", " ".join(argv))
        self.assertIn("%cpu", argv[-1])

    def test_sample_argv_uses_requested_interval(self):
        argv = profile.sample_argv(123, 20, 10, pathlib.Path("sample.txt"))
        self.assertEqual(
            argv,
            [
                "/usr/bin/sudo",
                "-n",
                "--",
                "/usr/bin/sample",
                "123",
                "20",
                "10",
                "-file",
                "sample.txt",
            ],
        )


class ProcessDiscoveryTests(unittest.TestCase):
    def test_helper_pids_extracts_only_vmm_helpers(self):
        listing = """
  11 1 501 0.0 0.1 1 2 S 00:01 /usr/bin/other
  22 1 501 7.5 1.0 3 4 R 00:02 /Library/x/container-krun-vmm-helper /tmp/a.json
  23 22 0 0.0 0.1 3 4 S 00:02 /usr/bin/sudo -n -- /Library/x/container-krun-vmm-helper /tmp/a.json
  33 1 501 1.0 0.2 5 6 S 00:03 container-runtime-krun
"""
        self.assertEqual(list(profile.helper_pids(listing)), [22])


    def test_helper_pids_ignores_sudo_wrapper(self):
        listing = """
  11262 11252 0 0.0 0.1 10416 488792128 S 00:03 /usr/bin/sudo -n -- /Library/x/container-krun-vmm-helper /tmp/container-id/config.json
  11300 11262 502 17.4 2.2 366848 490025904 S 00:02 /Library/x/container-krun-vmm-helper /tmp/container-id/config.json
"""
        self.assertEqual(list(profile.helper_pids(listing)), [11300])
        self.assertEqual(profile.find_new_helper(set(), listing, "container-id"), 11300)

    def test_find_new_helper_prefers_new_process(self):
        listing = """
  22 1 501 1.0 0.1 1 2 S 00:01 /Library/x/container-krun-vmm-helper /tmp/old.json
  44 1 501 8.0 0.2 3 4 R 00:01 /Library/x/container-krun-vmm-helper /tmp/new.json
"""
        self.assertEqual(profile.find_new_helper({22}, listing, "container-id"), 44)

    def test_find_new_helper_can_match_container_id(self):
        listing = """
  22 1 501 1.0 0.1 1 2 S 00:01 /Library/x/container-krun-vmm-helper /tmp/other.json
  44 1 501 8.0 0.2 3 4 R 00:01 /Library/x/container-krun-vmm-helper /tmp/container-id/config.json
"""
        self.assertEqual(profile.find_new_helper({22, 44}, listing, "container-id"), 44)

    def test_find_new_helper_rejects_ambiguous_processes(self):
        listing = """
  22 1 501 1.0 0.1 1 2 S 00:01 /Library/x/container-krun-vmm-helper /tmp/a.json
  44 1 501 8.0 0.2 3 4 R 00:01 /Library/x/container-krun-vmm-helper /tmp/b.json
"""
        with self.assertRaises(RuntimeError):
            profile.find_new_helper(set(), listing, "container-id")


class ProfilerWorkflowTests(unittest.TestCase):
    def run_profile(self, failure=None):
        """Run main with real benchmark helpers; replace only external commands.

        Container exec runs the exact embedded sender against a loopback sink.
        macOS process/tool output is simulated, not a host profiling test.
        """
        commands = []
        started = []
        source_calls = []
        run_subprocess = subprocess.run

        def command(argv, **kwargs):
            commands.append(list(argv))
            self.assertEqual(argv[0], "container")
            stdout = ""
            stderr = ""
            status = 0
            if argv[1] == "run":
                started.append(argv[argv.index("--name") + 1])
                status = 1 if failure == "start" else 0
                stdout = started[-1] + "\n"
            elif argv[1] == "logs":
                stdout = "READY\n"
            elif argv[1] == "inspect":
                stdout = json.dumps([{"status": {"networks": [{
                    "ipv4Address": "127.0.0.2/8", "ipv4Gateway": "127.0.0.1",
                }]}}])
            elif argv[1] == "exec":
                self.assertEqual(argv[2], started[-1])
                self.assertEqual(argv[3:5], ["python3", "-c"])
                self.assertEqual(argv[5], profile.streams_bench.GUEST_SOURCE)
                # No TCP sampling or congestion override is added by this task.
                self.assertEqual(len(argv), 11)
                source_calls.append(argv)
                stage = "warmup" if len(source_calls) == 1 else "source"
                if failure == stage:
                    status, stderr = 1, f"injected {stage} failure"
                else:
                    return run_subprocess([sys.executable, *argv[4:]], **kwargs)
            elif argv[1] == "delete":
                self.assertEqual(argv[2:], ["--force", started[-1]])
            else:
                self.fail(f"unexpected container command: {argv}")
            return subprocess.CompletedProcess(argv, status, stdout, stderr)

        def listing():
            if not started:
                return ""
            config = f"/tmp/Application Support/{started[-1]}/krun-vmm.json"
            helper = "/Library/test/container-krun-vmm-helper"
            return (
                f"21 1 0 0.0 0.1 1 2 S 00:01 /usr/bin/sudo -n -- {helper} {config}\n"
                f"22 21 501 2.0 0.1 1 2 R 00:01 {helper} {config}\n"
            )

        def capture(output, name, argv, timeout=30):
            (output / name).write_text("simulated macOS capture\n", encoding="utf-8")
            return 0

        def sample(pid, seconds, interval_ms, output):
            self.assertEqual(pid, 22)
            (output / "vmm-sample.txt").write_text("simulated stack sample\n", encoding="utf-8")

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            argv = [str(SCRIPT), "--runtime", "fixture-runtime", "--network", "fixture-network",
                    "--image", "fixture:image", "--streams", "2", "--seconds", "1.1",
                    "--warmup-seconds", "0.01", "--sample-delay", "0", "--sample-seconds", "1",
                    "--chunk-kib", "1", "--timeout", "10", "--result-root", directory]
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(sys, "argv", argv))
                stack.enter_context(mock.patch.object(profile.platform, "system", return_value="Darwin"))
                stack.enter_context(mock.patch.object(profile.platform, "platform", return_value="test-host"))
                stack.enter_context(mock.patch.object(profile.Path, "is_file", return_value=True))
                stack.enter_context(mock.patch.object(profile.shutil, "which", return_value="/usr/bin/sample"))
                stack.enter_context(mock.patch.object(profile, "authorize_profiler", autospec=True))
                stack.enter_context(mock.patch.object(profile, "process_listing", side_effect=listing))
                stack.enter_context(mock.patch.object(profile, "capture_command", autospec=True, side_effect=capture))
                start_top = stack.enter_context(mock.patch.object(profile, "start_top", autospec=True))
                finish_top = stack.enter_context(mock.patch.object(profile, "finish_top", autospec=True))
                run_sample = stack.enter_context(mock.patch.object(profile, "run_sample", autospec=True,
                                                                  side_effect=sample))
                stack.enter_context(mock.patch.object(profile.streams_bench, "git_head", return_value="test"))
                stack.enter_context(mock.patch.object(profile.streams_bench, "capture_guest_network_failure",
                                                      autospec=True))
                stack.enter_context(mock.patch.object(profile.subprocess, "run", side_effect=command))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                status = profile.main()

            output = next(root.glob("network-profile-*"))
            metadata = json.loads((output / "metadata.json").read_text())
            error_path = output / "fatal-error.txt"
            error = error_path.read_text() if error_path.exists() else None
            with tarfile.open(next(root.glob("*.tar.gz"))) as archive:
                archived_metadata = json.load(archive.extractfile(f"{output.name}/metadata.json"))
                self.assertEqual(archived_metadata, metadata)
                self.assertEqual(archived_metadata["result"], "PASS" if status == 0 else "FAIL")
                if status == 0:
                    self.assertIn(f"{output.name}/vmm-sample.txt", archive.getnames())
                    for name in ("warmup-result.json", "profile-result.json"):
                        result = json.load(archive.extractfile(f"{output.name}/{name}"))
                        self.assertGreater(result["bytes"], 0)
                        self.assertEqual(result["streams"], 2)
                else:
                    self.assertIn(f"{output.name}/fatal-error.txt", archive.getnames())

            self.assertEqual(len(started), 1, error)
            self.assertTrue(started[0].endswith("-r1"))
            start = next(argv for argv in commands if argv[1] == "run")
            self.assertEqual(start[start.index("--runtime") + 1], "fixture-runtime")
            self.assertEqual(start[start.index("--network") + 1], "fixture-network")
            self.assertIn("fixture:image", start)
            self.assertEqual(commands[-1], ["container", "delete", "--force", started[0]])
            if failure in ("start", "warmup"):
                start_top.assert_not_called()
                run_sample.assert_not_called()
            else:
                start_top.assert_called_once()
                run_sample.assert_called_once()
                finish_top.assert_called_once_with(start_top.return_value, 11)
                self.assertEqual(metadata["helper_pid"], 22)
            return status, error

    def test_main_uses_current_helpers_through_startup_transfer_and_archive(self):
        status, error = self.run_profile()
        self.assertEqual(status, 0, error)
        self.assertIsNone(error)

    def test_main_cleans_up_and_archives_endpoint_start_failure(self):
        status, error = self.run_profile(failure="start")
        self.assertEqual(status, 1)
        self.assertIn("fixture-runtime-start failed with exit 1", error)

    def test_main_cleans_up_and_archives_warmup_failure(self):
        status, error = self.run_profile(failure="warmup")
        self.assertEqual(status, 1)
        self.assertIn("profile-warmup failed with exit 1", error)

    def test_main_cleans_up_and_archives_measured_source_failure(self):
        status, error = self.run_profile(failure="source")
        self.assertEqual(status, 1)
        self.assertIn("profile-guest-to-host-source failed with exit 1", error)


if __name__ == "__main__":
    unittest.main()
