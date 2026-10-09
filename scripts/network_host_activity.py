"""Bounded, external macOS thread CPU observations for network profiling.

Uses the public libproc ABI in sys/proc_info.h. PROC_PIDLISTTHREADS returns
legacy per-process thread handles, NOT sample's system-wide Thread_<id> IDs.
No guest, runtime, scheduling, or socket settings are changed.
"""
from __future__ import annotations

import ctypes
import errno
import json
import threading
import time
from pathlib import Path


class ProcThreadInfo(ctypes.Structure):
    _fields_ = [
        ("user_ns", ctypes.c_uint64),
        ("system_ns", ctypes.c_uint64),
        *[(name, ctypes.c_int32) for name in (
            "cpu_usage", "policy", "run_state", "flags", "sleep_time",
            "current_priority", "priority", "max_priority",
        )],
        ("name", ctypes.c_char * 64),
    ]


class ThreadReader:
    def __init__(self) -> None:
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
        ]
        self.libproc.proc_pidinfo.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int

    def executable(self, pid: int) -> str:
        path = ctypes.create_string_buffer(4096)
        if self.libproc.proc_pidpath(pid, path, ctypes.sizeof(path)) <= 0:
            raise OSError(ctypes.get_errno(), f"proc_pidpath({pid}) failed")
        return path.value.decode("utf-8", errors="replace")

    def snapshot(self, pid: int) -> dict[str, object]:
        started = time.monotonic_ns()
        handles = (ctypes.c_uint64 * 4096)()
        size = ctypes.sizeof(handles)
        ctypes.set_errno(0)
        length = self.libproc.proc_pidinfo(pid, 6, 0, handles, size)
        if length <= 0:
            raise OSError(ctypes.get_errno(), f"PROC_PIDLISTTHREADS({pid}) failed")
        if length >= size or length % ctypes.sizeof(ctypes.c_uint64):
            raise RuntimeError(f"truncated or malformed thread list for PID {pid}: {length}")
        threads = []
        for handle in handles[:length // ctypes.sizeof(ctypes.c_uint64)]:
            info = ProcThreadInfo()
            ctypes.set_errno(0)
            length = self.libproc.proc_pidinfo(
                pid, 5, handle, ctypes.byref(info), ctypes.sizeof(info),
            )
            if length != ctypes.sizeof(info):
                # A sink thread may finish between enumeration and this read.
                if length == 0 and ctypes.get_errno() == errno.ESRCH:
                    continue
                raise OSError(ctypes.get_errno(), f"PROC_PIDTHREADINFO({pid}, {handle}) failed")
            threads.append({
                "handle": handle,
                "name": info.name.decode("utf-8", errors="replace"),
                "user_ns": info.user_ns,
                "system_ns": info.system_ns,
                "run_state": info.run_state,
            })
        finished = time.monotonic_ns()
        return {
            "pid": pid, "observed_ns": (started + finished) // 2,
            "read_duration_ns": finished - started, "threads": threads,
        }


def cpu_intervals(observations: list[dict[str, object]]) -> list[dict[str, object]]:
    """Report only consecutive observations of the same handle/name/counters.

    A newly observed, departed, renamed, or counter-reset thread is not assigned
    zero CPU time. Those intervals have no estimate. State snapshots do not
    distinguish runnable-but-unscheduled threads from threads executing on CPU.
    """
    intervals = []
    previous: dict[str, dict[str, object]] = {}
    for observation in observations:
        for role, snapshot in observation["processes"].items():
            before = previous.get(role)
            previous[role] = snapshot
            if before is None:
                continue
            elapsed = snapshot["observed_ns"] - before["observed_ns"]
            if elapsed <= 0 or snapshot["pid"] != before["pid"]:
                continue
            old = {row["handle"]: row for row in before["threads"]}
            for row in snapshot["threads"]:
                prior = old.get(row["handle"])
                if prior is None or prior["name"] != row["name"]:
                    continue
                user = row["user_ns"] - prior["user_ns"]
                system = row["system_ns"] - prior["system_ns"]
                if user < 0 or system < 0:
                    continue
                intervals.append({
                    "role": role, "pid": snapshot["pid"], "handle": row["handle"],
                    "name": row["name"], "start_ns": before["observed_ns"],
                    "end_ns": snapshot["observed_ns"], "user_ns": user,
                    "system_ns": system, "cpu_percent_one_core": 100 * (user + system) / elapsed,
                    "end_run_state": row["run_state"],
                })
    return intervals


class HostActivity:
    """One libproc sweep per second; fixed sample budget and bounded teardown."""
    def __init__(self, output: Path, pids: dict[str, int], seconds: int,
                 reader: ThreadReader | None = None) -> None:
        self.output = output
        self.pids = pids
        self.reader = reader or ThreadReader()
        self.sample_budget = seconds + 2
        self.stop_event = threading.Event()
        self.observations: list[dict[str, object]] = []
        self.errors: list[str] = []
        self.wall_anchor = {"monotonic_before_ns": time.monotonic_ns(), "unix_ns": time.time_ns(),
                            "monotonic_after_ns": time.monotonic_ns()}
        self.thread = threading.Thread(target=self._run, name="host-activity", daemon=True)

    def observe(self) -> None:
        processes = {role: self.reader.snapshot(pid) for role, pid in self.pids.items()}
        self.observations.append({"processes": processes})

    def start(self) -> None:
        # Synchronous preflight: a permission/ABI failure cannot become an empty PASS.
        self.observe()
        self.thread.start()

    def _run(self) -> None:
        try:
            for _ in range(self.sample_budget):
                if self.stop_event.wait(1):
                    break
                self.observe()
        except Exception as error:
            self.errors.append(repr(error))

    def finish(self) -> None:
        self.stop_event.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError("host activity collector did not terminate")
        if not self.errors:
            try:
                self.observe()
            except Exception as error:
                self.errors.append(repr(error))
        intervals = cpu_intervals(self.observations)
        missing = sorted(set(self.pids) - {row["role"] for row in intervals})
        if missing:
            self.errors.append(f"no consecutive thread CPU coverage for: {missing}")
        self.output.write_text(json.dumps({
            "clock": "host monotonic nanoseconds",
            "wall_anchor": self.wall_anchor,
            "cpu_time_unit": "nanoseconds",
            "thread_identity": "legacy libproc handle; not sample Thread_<id>",
            "run_states": {1: "running/runnable", 2: "stopped", 3: "waiting",
                           4: "uninterruptible", 5: "halted"},
            "sink_role": "harness_and_sink includes Python orchestration and observation overhead",
            "observations": self.observations, "cpu_intervals": intervals,
            "errors": self.errors,
        }, indent=2) + "\n", encoding="utf-8")
        if self.errors:
            raise RuntimeError(f"incomplete host activity evidence: {self.errors}")
