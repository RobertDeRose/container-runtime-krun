import importlib.util
import pathlib
import sys
import unittest


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


if __name__ == "__main__":
    unittest.main()
