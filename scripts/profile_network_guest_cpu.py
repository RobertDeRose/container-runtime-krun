#!/usr/bin/env python3
"""Profile guest CPU and softirq distribution during sustained native-vmnet TX."""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import tarfile
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
    eth0_device = str(Path("/sys/class/net/eth0/device").resolve())
except Exception:
    eth0_device = ""

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
            before = guest_snapshot(bench, endpoint, f"guest-snapshot-{iteration}-before")
            result = measure_guest_to_host(
                bench,
                endpoint,
                args.streams,
                args.seconds,
                args.chunk_kib * 1024,
                f"{label}-guest-to-host-p{args.streams}-{iteration}",
            )
            after = guest_snapshot(bench, endpoint, f"guest-snapshot-{iteration}-after")
            delta = snapshot_delta(before, after)
            rows.append({
                "iteration": iteration,
                "throughput_mib_per_second": float(result["mib_per_second"]),
                "delta": delta,
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
