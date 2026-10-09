import ctypes
import errno
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "network_host_activity.py"
SPEC = importlib.util.spec_from_file_location("network_host_activity", SCRIPT)
activity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = activity
SPEC.loader.exec_module(activity)


def observation(stamp, threads, pid=22):
    return {"processes": {"vmm": {"pid": pid, "observed_ns": stamp, "threads": threads}}}


def thread(handle=1, user=0, system=0, name="virtio-net worker"):
    return {"handle": handle, "user_ns": user, "system_ns": system, "name": name, "run_state": 1}


class CPUIntervalTests(unittest.TestCase):
    def test_cpu_time_is_scaled_against_actual_observation_interval(self):
        rows = activity.cpu_intervals([
            observation(100, [thread()]),
            observation(1_000_000_100, [thread(user=200_000_000, system=300_000_000)]),
        ])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cpu_percent_one_core"], 50)
        self.assertEqual(rows[0]["system_ns"], 300_000_000)

    def test_new_departed_renamed_or_reset_threads_are_not_reported_as_idle(self):
        for changed in ([thread(handle=2)], [], [thread(name="changed")],
                        [thread(user=1, system=0)]):
            with self.subTest(changed=changed):
                self.assertEqual(activity.cpu_intervals([
                    observation(1, [thread(user=10, system=10)]),
                    observation(100, changed),
                ]), [])

    def test_pid_change_and_nonpositive_time_do_not_produce_an_estimate(self):
        for end in (observation(1, [thread(user=10)]),
                    observation(100, [thread(user=10)], pid=23)):
            self.assertEqual(activity.cpu_intervals([observation(1, [thread()]), end]), [])

    def test_only_consecutive_snapshots_are_paired(self):
        self.assertEqual(activity.cpu_intervals([
            observation(1, [thread()]), observation(100, []),
            observation(200, [thread(user=50)]),
        ]), [])


class LibprocReaderTests(unittest.TestCase):
    def reader(self, listed_bytes=8, info_bytes=112, error=0):
        reader = activity.ThreadReader.__new__(activity.ThreadReader)

        def pidinfo(pid, flavor, handle, buffer, size):
            self.assertEqual(pid, 22)
            if flavor == 6:
                ctypes.cast(buffer, ctypes.POINTER(ctypes.c_uint64))[0] = 99
                return listed_bytes
            self.assertEqual((flavor, handle, size), (5, 99, 112))
            info = activity.ProcThreadInfo(user_ns=10, system_ns=20, run_state=3, name=b"worker")
            ctypes.memmove(buffer, ctypes.byref(info), ctypes.sizeof(info))
            ctypes.set_errno(error)
            return info_bytes

        reader.libproc = types.SimpleNamespace(proc_pidinfo=pidinfo)
        return reader

    def test_abi_and_decoding(self):
        self.assertEqual(ctypes.sizeof(activity.ProcThreadInfo), 112)
        snapshot = self.reader().snapshot(22)
        self.assertEqual(snapshot["threads"], [
            {"handle": 99, "name": "worker", "user_ns": 10, "system_ns": 20, "run_state": 3},
        ])
        self.assertGreaterEqual(snapshot["read_duration_ns"], 0)

    def test_malformed_and_full_thread_lists_fail(self):
        for length in (7, 4096 * 8, 4096 * 8 + 8):
            with self.subTest(length=length), self.assertRaises(RuntimeError):
                self.reader(listed_bytes=length).snapshot(22)

    def test_unreadable_list_or_thread_fails_not_empty_success(self):
        for reader in (self.reader(listed_bytes=0),
                       self.reader(info_bytes=0, error=errno.EPERM),
                       self.reader(info_bytes=4)):
            with self.assertRaises(OSError):
                reader.snapshot(22)

    def test_thread_departure_is_allowed(self):
        self.assertEqual(self.reader(info_bytes=0, error=errno.ESRCH).snapshot(22)["threads"], [])


class CollectorTests(unittest.TestCase):
    def fake_reader(self):
        reader = mock.Mock()
        count = 0

        def snapshot(pid):
            nonlocal count
            count += 1
            return {"pid": pid, "observed_ns": count * 1_000_000_000,
                    "threads": [thread(user=count * 10_000_000)]}
        reader.snapshot.side_effect = snapshot
        return reader

    def test_start_finish_archives_cpu_and_observer_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "activity.json"
            collector = activity.HostActivity(output, {"vmm": 22}, 1, self.fake_reader())
            collector.start()
            collector.finish()
            result = json.loads(output.read_text())
            self.assertEqual(len(result["observations"]), 2)
            self.assertEqual(len(result["cpu_intervals"]), 1)
            self.assertFalse(result["errors"])
            self.assertIn("not sample", result["thread_identity"])

    def test_sampling_is_budgeted_even_without_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            collector = activity.HostActivity(pathlib.Path(directory) / "activity.json",
                                              {"vmm": 22}, 1, self.fake_reader())
            collector.stop_event = mock.Mock()
            collector.stop_event.wait.return_value = False
            collector._run()
            self.assertEqual(len(collector.observations), 3)
            self.assertEqual(collector.stop_event.wait.call_count, 3)

    def test_failure_keeps_partial_evidence_and_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "activity.json"
            reader = self.fake_reader()
            collector = activity.HostActivity(output, {"vmm": 22}, 1, reader)
            collector.start()
            reader.snapshot.side_effect = OSError("denied")
            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                collector.finish()
            result = json.loads(output.read_text())
            self.assertEqual(len(result["observations"]), 1)
            self.assertIn("denied", result["errors"][0])


@unittest.skipUnless(sys.platform == "darwin", "requires public macOS libproc")
class NativeReaderTests(unittest.TestCase):
    def test_live_named_thread_cpu_counters_use_nanoseconds(self):
        ready = threading.Event()
        stop = threading.Event()

        def busy_thread():
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            lib.pthread_setname_np.argtypes = [ctypes.c_char_p]
            lib.pthread_setname_np(b"krun-cpu-probe")
            ready.set()
            while not stop.is_set():
                sum(range(1000))

        worker = threading.Thread(target=busy_thread)
        worker.start()
        try:
            self.assertTrue(ready.wait(2))
            reader = activity.ThreadReader()
            self.assertTrue(reader.executable(os.getpid()))
            before = reader.snapshot(os.getpid())
            time.sleep(0.1)
            after = reader.snapshot(os.getpid())
            rows = activity.cpu_intervals([
                {"processes": {"self": before}}, {"processes": {"self": after}},
            ])
            row = next(row for row in rows if row["name"] == "krun-cpu-probe")
            cpu_ns = row["user_ns"] + row["system_ns"]
            self.assertGreater(cpu_ns, 1_000_000)
            self.assertLess(cpu_ns, 2 * (row["end_ns"] - row["start_ns"]))
        finally:
            stop.set()
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())


if __name__ == "__main__":
    unittest.main()
