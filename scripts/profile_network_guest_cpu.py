#!/usr/bin/env python3
"""Profile guest CPU, softirq, and aggregate TX datapath behavior during native-vmnet TX."""

from __future__ import annotations

import argparse
import json
import os
import platform
import signal
import statistics
import subprocess
import tarfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import benchmark_network_streams as streams_bench

GUEST_SNAPSHOT = r'''
import json
from pathlib import Path


def read_text(path):
    try:
        return Path(path).read_text()
    except Exception as error:
        return f"ERROR: {error!r}"


queues = []
try:
    queues = sorted(path.name for path in Path("/sys/class/net/eth0/queues").iterdir())
except Exception:
    pass

try:
    eth0_device_path = Path("/sys/class/net/eth0/device").resolve()
    eth0_device = str(eth0_device_path)
except Exception:
    eth0_device_path = None
    eth0_device = ""

virtio_features = ""
virtio_status = ""
virtio_modalias = ""
virtio_uevent = ""
virtio_driver = ""
if eth0_device_path is not None:
    virtio_features = read_text(eth0_device_path / "features").strip()
    virtio_status = read_text(eth0_device_path / "status").strip()
    virtio_modalias = read_text(eth0_device_path / "modalias").strip()
    virtio_uevent = read_text(eth0_device_path / "uevent").strip()
    try:
        virtio_driver = str((eth0_device_path / "driver").resolve())
    except Exception:
        pass

queue_settings = {}
for queue in queues:
    base = Path("/sys/class/net/eth0/queues") / queue
    values = {}
    for name in ("rps_cpus", "rps_flow_cnt", "xps_cpus", "tx_maxrate"):
        path = base / name
        if path.exists():
            values[name] = read_text(path).strip()
    bql = base / "byte_queue_limits"
    if bql.exists():
        for name in ("limit", "limit_max", "limit_min", "inflight"):
            path = bql / name
            if path.exists():
                values[f"byte_queue_limits/{name}"] = read_text(path).strip()
    queue_settings[queue] = values

irq_affinity = {}
for path in sorted(Path("/proc/irq").glob("*/smp_affinity_list")):
    try:
        irq_affinity[path.parent.name] = path.read_text().strip()
    except Exception:
        pass

print(json.dumps({
    "proc_stat": read_text("/proc/stat"),
    "softirqs": read_text("/proc/softirqs"),
    "interrupts": read_text("/proc/interrupts"),
    "softnet_stat": read_text("/proc/net/softnet_stat"),
    "net_queues": queues,
    "eth0_device": eth0_device,
    "virtio_features": virtio_features,
    "virtio_status": virtio_status,
    "virtio_modalias": virtio_modalias,
    "virtio_uevent": virtio_uevent,
    "virtio_driver": virtio_driver,
    "queue_settings": queue_settings,
    "irq_affinity": irq_affinity,
}, sort_keys=True))
'''


def parse_proc_stat(text: str) -> dict[str, tuple[int, ...]]:
    result: dict[str, tuple[int, ...]] = {}
    for line in text.splitlines():
        fields = line.split()
        if not fields or not fields[0].startswith("cpu") or fields[0] == "cpu":
            continue
        if not fields[0][3:].isdigit():
            continue
        result[fields[0]] = tuple(int(value) for value in fields[1:])
    return result


def parse_softirqs(text: str) -> dict[str, list[int]]:
    result: dict[str, list[int]] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        name, values = line.split(":", 1)
        name = name.strip()
        fields = values.split()
        if not fields or not all(field.isdigit() for field in fields):
            continue
        result[name] = [int(field) for field in fields]
    return result


def parse_softnet_stat(text: str) -> list[dict[str, int]]:
    rows: list[dict[str, int]] = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        try:
            values = [int(field, 16) for field in fields]
        except ValueError:
            continue
        rows.append({
            "processed": values[0],
            "dropped": values[1],
            "time_squeeze": values[2],
        })
    return rows


def parse_interrupts(text: str) -> dict[str, dict[str, object]]:
    cpu_count = 0
    result: dict[str, dict[str, object]] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("CPU"):
            cpu_count = len(stripped.split())
            continue
        if ":" not in line or cpu_count == 0:
            continue
        irq, rest = line.split(":", 1)
        irq = irq.strip()
        if not irq.isdigit():
            continue
        fields = rest.split()
        if len(fields) < cpu_count:
            continue
        try:
            counts = [int(field) for field in fields[:cpu_count]]
        except ValueError:
            continue
        result[irq] = {
            "counts": counts,
            "description": " ".join(fields[cpu_count:]),
        }
    return result


def delta_vector(before: list[int], after: list[int]) -> list[int]:
    count = min(len(before), len(after))
    return [max(0, after[index] - before[index]) for index in range(count)]


def cpu_delta(before: str, after: str) -> list[dict[str, object]]:
    before_rows = parse_proc_stat(before)
    after_rows = parse_proc_stat(after)
    rows: list[dict[str, object]] = []
    for cpu in sorted(set(before_rows) & set(after_rows), key=lambda value: int(value[3:])):
        lhs = before_rows[cpu]
        rhs = after_rows[cpu]
        count = min(8, len(lhs), len(rhs))
        deltas = [max(0, rhs[index] - lhs[index]) for index in range(count)]
        total = sum(deltas)
        idle = (deltas[3] if len(deltas) > 3 else 0) + (deltas[4] if len(deltas) > 4 else 0)
        busy = max(0, total - idle)
        rows.append({
            "cpu": cpu,
            "busy_ticks": busy,
            "total_ticks": total,
            "utilization_percent": (100.0 * busy / total) if total else 0.0,
        })
    return rows


def softirq_delta(before: str, after: str) -> dict[str, dict[str, object]]:
    before_rows = parse_softirqs(before)
    after_rows = parse_softirqs(after)
    result: dict[str, dict[str, object]] = {}
    for name in ("NET_RX", "NET_TX"):
        if name not in before_rows or name not in after_rows:
            continue
        per_cpu = delta_vector(before_rows[name], after_rows[name])
        result[name] = {"per_cpu": per_cpu, "total": sum(per_cpu)}
    return result


def softnet_delta(before: str, after: str) -> list[dict[str, int]]:
    lhs = parse_softnet_stat(before)
    rhs = parse_softnet_stat(after)
    rows: list[dict[str, int]] = []
    for index in range(min(len(lhs), len(rhs))):
        rows.append({
            "cpu": index,
            "processed": max(0, rhs[index]["processed"] - lhs[index]["processed"]),
            "dropped": max(0, rhs[index]["dropped"] - lhs[index]["dropped"]),
            "time_squeeze": max(0, rhs[index]["time_squeeze"] - lhs[index]["time_squeeze"]),
        })
    return rows


def interrupt_delta(before: str, after: str, eth0_device: str) -> list[dict[str, object]]:
    lhs = parse_interrupts(before)
    rhs = parse_interrupts(after)
    device_name = Path(eth0_device).name if eth0_device else ""
    rows: list[dict[str, object]] = []
    for irq in set(lhs) & set(rhs):
        before_counts = lhs[irq]["counts"]
        after_counts = rhs[irq]["counts"]
        assert isinstance(before_counts, list) and isinstance(after_counts, list)
        per_cpu = delta_vector(before_counts, after_counts)
        total = sum(per_cpu)
        description = str(rhs[irq]["description"])
        if total == 0:
            continue
        rows.append({
            "irq": irq,
            "description": description,
            "per_cpu": per_cpu,
            "total": total,
            "matches_eth0_device": bool(device_name and device_name in description),
        })
    rows.sort(key=lambda row: (not bool(row["matches_eth0_device"]), -int(row["total"])))
    return rows[:20]


@dataclass(frozen=True)
class KrunHelperProcess:
    pid: int
    config_path: Path
    log_path: Path


def parse_krun_helper_processes(text: str) -> dict[int, KrunHelperProcess]:
    helpers: dict[int, KrunHelperProcess] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, separator, command = stripped.partition(" ")
        if not separator:
            continue
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        command = command.strip()
        executable, separator, config_text = command.partition(" ")
        # The runtime launches the VMM through ``sudo -n -- helper ...``.
        # The sudo wrapper therefore contains the helper name in its argv, but
        # signals must target the helper process itself.
        if not separator or Path(executable).name != "container-krun-vmm-helper":
            continue
        # macOS ps renders argv as whitespace-separated text without restoring
        # quotes around an argument that contains spaces. The VMM helper accepts
        # exactly one argument, so the entire remainder is the config path.
        config_text = config_text.strip()
        if not config_text.endswith("krun-vmm.json"):
            continue
        config = Path(config_text)
        helpers[pid] = KrunHelperProcess(pid=pid, config_path=config, log_path=config.parent / "krun-vmm.log")
    return helpers


def krun_helper_processes() -> dict[int, KrunHelperProcess]:
    result = subprocess.run(
        ["/bin/ps", "-ww", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        check=True,
        timeout=5,
    )
    return parse_krun_helper_processes(result.stdout)


def find_new_krun_helper(
    baseline_pids: set[int], container_id: str, timeout: float = 5.0
) -> KrunHelperProcess:
    deadline = time.monotonic() + timeout
    last_new: list[KrunHelperProcess] = []
    while time.monotonic() < deadline:
        current = krun_helper_processes()
        new = [helper for pid, helper in current.items() if pid not in baseline_pids]
        matching = [helper for helper in new if container_id in str(helper.config_path)]
        if len(matching) == 1:
            return matching[0]
        if len(new) == 1:
            return new[0]
        last_new = new
        time.sleep(0.05)
    raise RuntimeError(
        f"could not identify one new container-krun-vmm-helper for {container_id}: "
        f"{[(helper.pid, str(helper.config_path)) for helper in last_new]}"
    )


def signal_tx_datapath(
    helper: KrunHelperProcess, signum: int, prefix: str, timeout: float = 5.0
) -> dict[str, object]:
    try:
        offset = helper.log_path.stat().st_size
    except FileNotFoundError:
        offset = 0
    os.kill(helper.pid, signum)
    deadline = time.monotonic() + timeout
    pending = b""
    with helper.log_path.open("rb") as stream:
        stream.seek(offset)
        while time.monotonic() < deadline:
            chunk = stream.read()
            if chunk:
                pending += chunk
                while b"\n" in pending:
                    raw_line, pending = pending.split(b"\n", 1)
                    line = raw_line.decode("utf-8", errors="replace")
                    if line.startswith("KRUN_TX_DATAPATH_ERROR "):
                        raise RuntimeError(line)
                    marker = prefix + " "
                    if line.startswith(marker):
                        payload = json.loads(line[len(marker):])
                        if not isinstance(payload, dict):
                            raise RuntimeError(f"invalid {prefix} payload: {payload!r}")
                        if int(payload.get("network_index", -1)) == 0:
                            return payload
            time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {prefix} from helper PID {helper.pid}")


def reset_tx_datapath(helper: KrunHelperProcess) -> None:
    payload = signal_tx_datapath(helper, signal.SIGUSR2, "KRUN_TX_DATAPATH_RESET")
    if int(payload.get("result", -1)) != 0:
        raise RuntimeError(f"libkrun rejected TX datapath reset: {payload}")


TX_HANDOFF_REQUIRED_FIELDS = {
    "notify_to_eventfd_samples",
    "notify_to_eventfd_sample_ns",
    "notify_to_eventfd_max_ns",
    "eventfd_write_samples",
    "eventfd_write_sample_ns",
    "eventfd_write_max_ns",
    "notify_while_worker_waiting_samples",
    "notify_while_worker_busy_samples",
    "notify_to_kqueue_ready_samples",
    "notify_to_kqueue_ready_sample_ns",
    "notify_to_kqueue_ready_max_ns",
    "kqueue_ready_to_eventfd_samples",
    "kqueue_ready_to_eventfd_sample_ns",
    "kqueue_ready_to_eventfd_max_ns",
    "irq_to_next_notify_samples",
    "irq_to_next_notify_sample_ns",
    "irq_to_next_notify_max_ns",
}


def snapshot_tx_datapath(helper: KrunHelperProcess) -> dict[str, object]:
    payload = signal_tx_datapath(helper, signal.SIGUSR1, "KRUN_TX_DATAPATH_STATS")
    missing = sorted(TX_HANDOFF_REQUIRED_FIELDS - payload.keys())
    if missing:
        raise RuntimeError(
            "running libkrun lacks TX handoff instrumentation fields: "
            + ", ".join(missing)
            + "; rebuild libkrun and reinstall the native runtime before profiling"
        )
    return payload


def _ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def tx_datapath_derived(
    counters: dict[str, object], result: dict[str, object], delta: dict[str, object]
) -> dict[str, float | None]:
    elapsed = float(result.get("elapsed_seconds", 0.0))
    frames = float(counters.get("frames", 0))
    datapath_bytes = float(counters.get("backend_bytes", counters.get("bytes", 0)))
    kicks = float(counters.get("queue_notify_writes", 0))
    wakeups = float(counters.get("eventfd_wakeups", 0))
    drains = float(counters.get("drain_passes", 0))
    chains = float(counters.get("descriptor_chains", 0))
    descriptors = float(counters.get("descriptors", 0))
    backend_calls = float(counters.get("write_frame_calls", 0))
    flushes = float(counters.get("flush_calls", 0))
    sampled_frames = float(counters.get("timing_sampled_frames", 0))
    descriptor_parse_ns = float(counters.get("descriptor_parse_sample_ns", 0))
    guest_copy_ns = float(counters.get("guest_copy_sample_ns", 0))
    backend_write_ns = float(counters.get("backend_write_sample_ns", 0))
    sampled_flushes = float(counters.get("timing_sampled_flushes", 0))
    flush_sample_ns = float(counters.get("flush_sample_ns", 0))
    sampled_drain_cycles = float(counters.get("timing_sampled_drain_cycles", 0))
    sampled_drain_frames = float(counters.get("timing_sampled_drain_frames", 0))
    drain_cycle_sample_ns = float(counters.get("drain_cycle_sample_ns", 0))
    tx_queue_disable_sample_ns = float(counters.get("tx_queue_disable_sample_ns", 0))
    tx_queue_enable_sample_ns = float(counters.get("tx_queue_enable_sample_ns", 0))
    add_used_sample_ns = float(counters.get("add_used_sample_ns", 0))
    sampled_notification_checks = float(counters.get("timing_sampled_notification_checks", 0))
    notification_check_sample_ns = float(counters.get("notification_check_sample_ns", 0))
    sampled_irq_signals = float(counters.get("timing_sampled_irq_signals", 0))
    irq_signal_sample_ns = float(counters.get("irq_signal_sample_ns", 0))
    notify_to_eventfd_samples = float(counters.get("notify_to_eventfd_samples", 0))
    notify_to_eventfd_sample_ns = float(counters.get("notify_to_eventfd_sample_ns", 0))
    eventfd_write_samples = float(counters.get("eventfd_write_samples", 0))
    eventfd_write_sample_ns = float(counters.get("eventfd_write_sample_ns", 0))
    notify_waiting_samples = float(counters.get("notify_while_worker_waiting_samples", 0))
    notify_busy_samples = float(counters.get("notify_while_worker_busy_samples", 0))
    notify_to_kqueue_ready_samples = float(counters.get("notify_to_kqueue_ready_samples", 0))
    notify_to_kqueue_ready_sample_ns = float(counters.get("notify_to_kqueue_ready_sample_ns", 0))
    kqueue_ready_to_eventfd_samples = float(counters.get("kqueue_ready_to_eventfd_samples", 0))
    kqueue_ready_to_eventfd_sample_ns = float(counters.get("kqueue_ready_to_eventfd_sample_ns", 0))
    irq_to_next_notify_samples = float(counters.get("irq_to_next_notify_samples", 0))
    irq_to_next_notify_sample_ns = float(counters.get("irq_to_next_notify_sample_ns", 0))
    sampled_frame_component_ns = descriptor_parse_ns + guest_copy_ns + backend_write_ns
    datapath_gib = datapath_bytes / (1024**3)

    interrupts = delta.get("interrupts", [])
    guest_irq = 0.0
    if isinstance(interrupts, list):
        guest_irq = float(
            sum(
                int(item.get("total", 0))
                for item in interrupts
                if isinstance(item, dict) and item.get("matches_eth0_device")
            )
        )

    return {
        "tx_kicks_per_second": _ratio(kicks, elapsed),
        "tx_kicks_per_gib": _ratio(kicks, datapath_gib),
        "eventfd_wakeups_per_second": _ratio(wakeups, elapsed),
        "eventfd_values_per_wakeup": _ratio(float(counters.get("eventfd_values", 0)), wakeups),
        "frames_per_worker_wakeup": _ratio(frames, wakeups),
        "mib_per_worker_wakeup": _ratio(datapath_bytes / (1024**2), wakeups),
        "descriptor_chains_per_wakeup": _ratio(chains, wakeups),
        "descriptors_per_frame": _ratio(descriptors, frames),
        "backend_calls_per_frame": _ratio(backend_calls, frames),
        "flushes_per_gib": _ratio(flushes, datapath_gib),
        "guest_irq_per_tx_kick": _ratio(guest_irq, kicks),
        "frames_per_drain": _ratio(frames, drains),
        "mib_per_drain": _ratio(datapath_bytes / (1024**2), drains),
        "empty_drain_fraction": _ratio(float(counters.get("empty_drain_passes", 0)), drains),
        "frames_per_flush": _ratio(float(counters.get("frames_between_flushes", 0)), flushes),
        "mib_per_flush": _ratio(float(counters.get("bytes_between_flushes", 0)) / (1024**2), flushes),
        "descriptor_parse_ns_per_sampled_frame": _ratio(descriptor_parse_ns, sampled_frames),
        "guest_copy_ns_per_sampled_frame": _ratio(guest_copy_ns, sampled_frames),
        "backend_write_ns_per_sampled_frame": _ratio(backend_write_ns, sampled_frames),
        "descriptor_parse_sample_percent": _ratio(
            100.0 * descriptor_parse_ns, sampled_frame_component_ns
        ),
        "guest_copy_sample_percent": _ratio(
            100.0 * guest_copy_ns, sampled_frame_component_ns
        ),
        "backend_write_sample_percent": _ratio(
            100.0 * backend_write_ns, sampled_frame_component_ns
        ),
        "flush_ns_per_sampled_call": _ratio(flush_sample_ns, sampled_flushes),
        "drain_cycle_ns_per_sampled_cycle": _ratio(
            drain_cycle_sample_ns, sampled_drain_cycles
        ),
        "frames_per_sampled_drain_cycle": _ratio(
            sampled_drain_frames, sampled_drain_cycles
        ),
        "drain_cycle_ns_per_sampled_frame": _ratio(
            drain_cycle_sample_ns, sampled_drain_frames
        ),
        "tx_queue_disable_ns_per_sampled_cycle": _ratio(
            tx_queue_disable_sample_ns, sampled_drain_cycles
        ),
        "tx_queue_enable_ns_per_sampled_cycle": _ratio(
            tx_queue_enable_sample_ns, sampled_drain_cycles
        ),
        "add_used_ns_per_sampled_frame": _ratio(add_used_sample_ns, sampled_frames),
        "notification_check_ns_per_sampled_call": _ratio(
            notification_check_sample_ns, sampled_notification_checks
        ),
        "irq_signal_ns_per_sampled_call": _ratio(irq_signal_sample_ns, sampled_irq_signals),
        "notify_to_eventfd_ns_per_sample": _ratio(
            notify_to_eventfd_sample_ns, notify_to_eventfd_samples
        ),
        "notify_to_eventfd_max_ns": (
            float(counters.get("notify_to_eventfd_max_ns", 0))
            if notify_to_eventfd_samples
            else None
        ),
        "eventfd_write_ns_per_sample": _ratio(
            eventfd_write_sample_ns, eventfd_write_samples
        ),
        "eventfd_write_max_ns": (
            float(counters.get("eventfd_write_max_ns", 0))
            if eventfd_write_samples
            else None
        ),
        "notify_to_worker_minus_eventfd_write_ns_per_sample": (
            max(
                0.0,
                notify_to_eventfd_sample_ns / notify_to_eventfd_samples
                - eventfd_write_sample_ns / eventfd_write_samples,
            )
            if notify_to_eventfd_samples and eventfd_write_samples
            else None
        ),
        "notify_worker_waiting_fraction": _ratio(
            notify_waiting_samples, notify_waiting_samples + notify_busy_samples
        ),
        "notify_to_kqueue_ready_ns_per_sample": _ratio(
            notify_to_kqueue_ready_sample_ns, notify_to_kqueue_ready_samples
        ),
        "notify_to_kqueue_ready_max_ns": (
            float(counters.get("notify_to_kqueue_ready_max_ns", 0))
            if notify_to_kqueue_ready_samples
            else None
        ),
        "kqueue_ready_to_eventfd_ns_per_sample": _ratio(
            kqueue_ready_to_eventfd_sample_ns, kqueue_ready_to_eventfd_samples
        ),
        "kqueue_ready_to_eventfd_max_ns": (
            float(counters.get("kqueue_ready_to_eventfd_max_ns", 0))
            if kqueue_ready_to_eventfd_samples
            else None
        ),
        "irq_to_next_notify_ns_per_sample": _ratio(
            irq_to_next_notify_sample_ns, irq_to_next_notify_samples
        ),
        "irq_to_next_notify_max_ns": (
            float(counters.get("irq_to_next_notify_max_ns", 0))
            if irq_to_next_notify_samples
            else None
        ),
        "estimated_tx_drain_active_fraction": _ratio(
            _ratio(drain_cycle_sample_ns, sampled_drain_cycles) * drains
            if sampled_drain_cycles
            else 0.0,
            elapsed * 1_000_000_000.0,
        ),
    }


def enabled_virtio_feature_bits(value: object) -> list[int]:
    if not isinstance(value, str):
        return []
    bits = value.strip()
    if not bits or any(bit not in "01" for bit in bits):
        return []
    return [index for index, bit in enumerate(bits) if bit == "1"]


def snapshot_delta(before: dict[str, object], after: dict[str, object]) -> dict[str, object]:
    return {
        "cpu": cpu_delta(str(before.get("proc_stat", "")), str(after.get("proc_stat", ""))),
        "softirqs": softirq_delta(str(before.get("softirqs", "")), str(after.get("softirqs", ""))),
        "softnet": softnet_delta(str(before.get("softnet_stat", "")), str(after.get("softnet_stat", ""))),
        "interrupts": interrupt_delta(
            str(before.get("interrupts", "")),
            str(after.get("interrupts", "")),
            str(after.get("eth0_device", "")),
        ),
        "net_queues": after.get("net_queues", []),
        "eth0_device": after.get("eth0_device", ""),
        "virtio_features": after.get("virtio_features", ""),
        "enabled_virtio_feature_bits": enabled_virtio_feature_bits(
            after.get("virtio_features", "")
        ),
        "virtio_status": after.get("virtio_status", ""),
        "virtio_modalias": after.get("virtio_modalias", ""),
        "virtio_uevent": after.get("virtio_uevent", ""),
        "virtio_driver": after.get("virtio_driver", ""),
        "queue_settings": after.get("queue_settings", {}),
        "irq_affinity": after.get("irq_affinity", {}),
    }


def guest_snapshot(
    bench: streams_bench.Benchmark,
    endpoint: streams_bench.Endpoint,
    label: str,
) -> dict[str, object]:
    result = bench.run(
        label,
        ["container", "exec", endpoint.container_id, "python3", "-c", GUEST_SNAPSHOT],
    )
    payload = streams_bench.parse_json_line(result.stdout)
    (bench.output / f"{label}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def measure_guest_to_host(
    bench: streams_bench.Benchmark,
    endpoint: streams_bench.Endpoint,
    streams: int,
    seconds: float,
    chunk_bytes: int,
    label: str,
) -> dict[str, object]:
    with streams_bench.SinkServer(endpoint.gateway) as sink:
        return streams_bench.guest_source(
            bench,
            endpoint,
            endpoint.gateway,
            sink.port,
            streams,
            seconds,
            chunk_bytes,
            label,
        )


def write_profile_summary(output: Path, rows: list[dict[str, object]]) -> None:
    (output / "guest-cpu-profile.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    with (output / "guest-cpu-profile.tsv").open("w", encoding="utf-8") as stream:
        stream.write(
            "iteration\tcpu\tutilization_percent\tnet_rx_softirqs\tnet_tx_softirqs\t"
            "softnet_processed\tsoftnet_dropped\tsoftnet_time_squeeze\n"
        )
        for row in rows:
            iteration = int(row["iteration"])
            delta = row["delta"]
            assert isinstance(delta, dict)
            cpu_rows = delta.get("cpu", [])
            softirqs = delta.get("softirqs", {})
            softnet = delta.get("softnet", [])
            assert isinstance(cpu_rows, list) and isinstance(softirqs, dict) and isinstance(softnet, list)
            rx = softirqs.get("NET_RX", {})
            tx = softirqs.get("NET_TX", {})
            rx_per_cpu = rx.get("per_cpu", []) if isinstance(rx, dict) else []
            tx_per_cpu = tx.get("per_cpu", []) if isinstance(tx, dict) else []
            softnet_by_cpu = {
                int(item["cpu"]): item for item in softnet if isinstance(item, dict) and "cpu" in item
            }
            for index, cpu_row in enumerate(cpu_rows):
                if not isinstance(cpu_row, dict):
                    continue
                net = softnet_by_cpu.get(index, {})
                stream.write(
                    f"{iteration}\t{cpu_row.get('cpu', f'cpu{index}')}\t"
                    f"{float(cpu_row.get('utilization_percent', 0.0)):.3f}\t"
                    f"{int(rx_per_cpu[index]) if index < len(rx_per_cpu) else 0}\t"
                    f"{int(tx_per_cpu[index]) if index < len(tx_per_cpu) else 0}\t"
                    f"{int(net.get('processed', 0))}\t{int(net.get('dropped', 0))}\t"
                    f"{int(net.get('time_squeeze', 0))}\n"
                )


def write_tx_datapath_summary(output: Path, rows: list[dict[str, object]]) -> None:
    records = [
        {
            "iteration": row["iteration"],
            "throughput_mib_per_second": row["throughput_mib_per_second"],
            "raw": row.get("tx_datapath", {}).get("raw", {}),
            "derived": row.get("tx_datapath", {}).get("derived", {}),
        }
        for row in rows
        if isinstance(row.get("tx_datapath"), dict)
    ]
    (output / "tx-datapath-profile.json").write_text(
        json.dumps(records, indent=2) + "\n", encoding="utf-8"
    )
    keys = [
        "tx_kicks_per_second",
        "tx_kicks_per_gib",
        "eventfd_wakeups_per_second",
        "frames_per_worker_wakeup",
        "mib_per_worker_wakeup",
        "descriptor_chains_per_wakeup",
        "descriptors_per_frame",
        "backend_calls_per_frame",
        "flushes_per_gib",
        "guest_irq_per_tx_kick",
        "descriptor_parse_ns_per_sampled_frame",
        "guest_copy_ns_per_sampled_frame",
        "backend_write_ns_per_sampled_frame",
        "descriptor_parse_sample_percent",
        "guest_copy_sample_percent",
        "backend_write_sample_percent",
        "flush_ns_per_sampled_call",
        "drain_cycle_ns_per_sampled_cycle",
        "frames_per_sampled_drain_cycle",
        "drain_cycle_ns_per_sampled_frame",
        "tx_queue_disable_ns_per_sampled_cycle",
        "tx_queue_enable_ns_per_sampled_cycle",
        "add_used_ns_per_sampled_frame",
        "notification_check_ns_per_sampled_call",
        "irq_signal_ns_per_sampled_call",
        "notify_to_eventfd_ns_per_sample",
        "notify_to_eventfd_max_ns",
        "eventfd_write_ns_per_sample",
        "eventfd_write_max_ns",
        "notify_to_worker_minus_eventfd_write_ns_per_sample",
        "notify_worker_waiting_fraction",
        "notify_to_kqueue_ready_ns_per_sample",
        "notify_to_kqueue_ready_max_ns",
        "kqueue_ready_to_eventfd_ns_per_sample",
        "kqueue_ready_to_eventfd_max_ns",
        "irq_to_next_notify_ns_per_sample",
        "irq_to_next_notify_max_ns",
        "estimated_tx_drain_active_fraction",
    ]
    with (output / "tx-datapath-profile.tsv").open("w", encoding="utf-8") as stream:
        stream.write("iteration\tthroughput_mib_per_second\t" + "\t".join(keys) + "\n")
        for record in records:
            derived = record["derived"]
            assert isinstance(derived, dict)
            values = []
            for key in keys:
                value = derived.get(key)
                values.append("" if value is None else f"{float(value):.6f}")
            stream.write(
                f"{int(record['iteration'])}\t{float(record['throughput_mib_per_second']):.6f}\t"
                + "\t".join(values)
                + "\n"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", default="default")
    parser.add_argument("--image", default="python:3.13-alpine")
    parser.add_argument("--streams", type=int, default=8)
    parser.add_argument("--cpus", type=int, default=8)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    if args.streams <= 0 or args.cpus <= 0 or args.seconds <= 0 or args.warmup_seconds <= 0:
        parser.error("streams, cpus, seconds, and warmup-seconds must be positive")
    if args.iterations <= 0 or args.chunk_kib <= 0:
        parser.error("iterations and chunk-kib must be positive")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"network-guest-cpu-profile-{token}"
    archive = args.result_root / f"container-runtime-krun-network-guest-cpu-profile-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    bench = streams_bench.Benchmark(output, args.timeout)
    prefix = f"krun-gcpu-{token.lower()}"
    label = f"krun-native-guest-cpu{args.cpus}"
    rows: list[dict[str, object]] = []
    baseline_helper_pids = set(krun_helper_processes())

    (output / "metadata.json").write_text(
        json.dumps(
            {
                "runtime": "container-runtime-krun",
                "backend": "native",
                "label": label,
                "network": args.network,
                "image": args.image,
                "streams": args.streams,
                "cpus": args.cpus,
                "seconds": args.seconds,
                "warmup_seconds": args.warmup_seconds,
                "iterations": args.iterations,
                "chunk_kib": args.chunk_kib,
                "repository_head": streams_bench.git_head(Path.cwd()),
                "libkrun_head": streams_bench.git_head(Path(".build-deps/libkrun")),
                "platform": platform.platform(),
                "machine": platform.machine(),
                "tx_datapath_instrumentation": "signal-triggered aggregate counters",
                "tx_datapath_timing_collected": True,
                "tx_datapath_timing_mode": "1-in-64 frame, drain-cycle, completion, handoff, and flush sampling",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    try:
        endpoint = streams_bench.start_endpoint(
            bench,
            "container-runtime-krun",
            label,
            args.image,
            args.network,
            prefix,
            1,
            args.cpus,
        )
        helper = find_new_krun_helper(baseline_helper_pids, endpoint.container_id)
        bench.log(
            f"TX datapath helper pid={helper.pid} config={helper.config_path} log={helper.log_path}"
        )
        reset_tx_datapath(helper)
        snapshot_tx_datapath(helper)
        bench.log("TX datapath handoff instrumentation preflight passed")
        bench.log(f"warmup {label} guest_to_host P{args.streams}")
        measure_guest_to_host(
            bench,
            endpoint,
            args.streams,
            args.warmup_seconds,
            args.chunk_kib * 1024,
            f"{label}-warmup",
        )

        for iteration in range(1, args.iterations + 1):
            reset_tx_datapath(helper)
            before = guest_snapshot(bench, endpoint, f"guest-snapshot-{iteration}-before")
            try:
                result = measure_guest_to_host(
                    bench,
                    endpoint,
                    args.streams,
                    args.seconds,
                    args.chunk_kib * 1024,
                    f"{label}-guest-to-host-p{args.streams}-{iteration}",
                )
            except Exception:
                try:
                    failed_tx_raw = snapshot_tx_datapath(helper)
                    (output / f"tx-datapath-{iteration}-failed.json").write_text(
                        json.dumps({"raw": failed_tx_raw}, indent=2) + "\n",
                        encoding="utf-8",
                    )
                except Exception as snapshot_error:
                    (output / f"tx-datapath-{iteration}-failed.txt").write_text(
                        repr(snapshot_error) + "\n", encoding="utf-8"
                    )
                raise
            tx_raw = snapshot_tx_datapath(helper)
            after = guest_snapshot(bench, endpoint, f"guest-snapshot-{iteration}-after")
            delta = snapshot_delta(before, after)
            tx_derived = tx_datapath_derived(tx_raw, result, delta)
            tx_record = {"raw": tx_raw, "derived": tx_derived}
            (output / f"tx-datapath-{iteration}.json").write_text(
                json.dumps(tx_record, indent=2) + "\n", encoding="utf-8"
            )
            rows.append({
                "iteration": iteration,
                "throughput_mib_per_second": float(result["mib_per_second"]),
                "delta": delta,
                "tx_datapath": tx_record,
            })
            bench.record(
                streams_bench.Sample(
                    runtime=label,
                    direction="guest_to_host",
                    streams=args.streams,
                    iteration=iteration,
                    bytes=int(result["bytes"]),
                    elapsed_seconds=float(result["elapsed_seconds"]),
                    completion_elapsed_seconds=float(result["completion_elapsed_seconds"]),
                    mib_per_second=float(result["mib_per_second"]),
                    status=0,
                )
            )

        if rows:
            medians: dict[str, float] = {}
            cpu_names = [str(item["cpu"]) for item in rows[0]["delta"]["cpu"]]
            for cpu in cpu_names:
                values = []
                for row in rows:
                    for item in row["delta"]["cpu"]:
                        if item["cpu"] == cpu:
                            values.append(float(item["utilization_percent"]))
                if values:
                    medians[cpu] = statistics.median(values)
            (output / "guest-cpu-median-utilization.json").write_text(
                json.dumps(medians, indent=2) + "\n", encoding="utf-8"
            )
    except Exception as error:
        bench.failed = True
        bench.log(f"fatal guest CPU profile error: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        write_profile_summary(output, rows)
        write_tx_datapath_summary(output, rows)
        bench.cleanup()
        streams_bench.write_results(bench, label, "unused")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if bench.failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
