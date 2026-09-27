#!/usr/bin/env python3
"""Compare Apple/VZ and krun guest CPU/IRQ behavior during sustained TX."""

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
import profile_network_guest_cpu as guest_profile


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


def profile_endpoint(
    bench: streams_bench.Benchmark,
    endpoint: streams_bench.Endpoint,
    label: str,
    *,
    streams: int,
    seconds: float,
    warmup_seconds: float,
    iterations: int,
    chunk_bytes: int,
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    bench.log(f"warmup {label} guest_to_host P{streams}")
    measure_guest_to_host(
        bench,
        endpoint,
        streams,
        warmup_seconds,
        chunk_bytes,
        f"{label}-warmup",
    )

    for iteration in range(1, iterations + 1):
        before = guest_profile.guest_snapshot(
            bench,
            endpoint,
            f"{label}-guest-snapshot-{iteration}-before",
        )
        result = measure_guest_to_host(
            bench,
            endpoint,
            streams,
            seconds,
            chunk_bytes,
            f"{label}-guest-to-host-p{streams}-{iteration}",
        )
        after = guest_profile.guest_snapshot(
            bench,
            endpoint,
            f"{label}-guest-snapshot-{iteration}-after",
        )
        delta = guest_profile.snapshot_delta(before, after)
        rows.append(
            {
                "iteration": iteration,
                "throughput_mib_per_second": float(result["mib_per_second"]),
                "delta": delta,
            }
        )
        bench.record(
            streams_bench.Sample(
                runtime=label,
                direction="guest_to_host",
                streams=streams,
                iteration=iteration,
                bytes=int(result["bytes"]),
                elapsed_seconds=float(result["elapsed_seconds"]),
                completion_elapsed_seconds=float(result["completion_elapsed_seconds"]),
                mib_per_second=float(result["mib_per_second"]),
                status=0,
            )
        )
    return rows


def _sum_vectors(vectors: list[list[int]]) -> list[int]:
    width = max((len(vector) for vector in vectors), default=0)
    result = [0] * width
    for vector in vectors:
        for index, value in enumerate(vector):
            result[index] += int(value)
    return result


def summarize_profile(rows: list[dict[str, object]]) -> dict[str, object]:
    throughputs = [float(row["throughput_mib_per_second"]) for row in rows]
    cpu_values: dict[str, list[float]] = {}
    eth_irq_vectors: list[list[int]] = []
    net_rx_vectors: list[list[int]] = []
    softnet_vectors: list[list[int]] = []
    queue_layouts: list[list[str]] = []

    for row in rows:
        delta = row.get("delta", {})
        if not isinstance(delta, dict):
            continue
        for cpu in delta.get("cpu", []):
            if isinstance(cpu, dict):
                cpu_values.setdefault(str(cpu.get("cpu", "")), []).append(
                    float(cpu.get("utilization_percent", 0.0))
                )
        softirqs = delta.get("softirqs", {})
        if isinstance(softirqs, dict):
            net_rx = softirqs.get("NET_RX", {})
            if isinstance(net_rx, dict) and isinstance(net_rx.get("per_cpu"), list):
                net_rx_vectors.append([int(value) for value in net_rx["per_cpu"]])
        softnet = delta.get("softnet", [])
        if isinstance(softnet, list):
            by_cpu: dict[int, int] = {}
            for item in softnet:
                if isinstance(item, dict):
                    by_cpu[int(item.get("cpu", 0))] = int(item.get("processed", 0))
            if by_cpu:
                softnet_vectors.append([by_cpu.get(index, 0) for index in range(max(by_cpu) + 1)])
        interrupts = delta.get("interrupts", [])
        if isinstance(interrupts, list):
            for item in interrupts:
                if isinstance(item, dict) and item.get("matches_eth0_device"):
                    vector = item.get("per_cpu", [])
                    if isinstance(vector, list):
                        eth_irq_vectors.append([int(value) for value in vector])
                    break
        queues = delta.get("net_queues", [])
        if isinstance(queues, list):
            queue_layouts.append([str(value) for value in queues])

    median_cpu = {
        cpu: statistics.median(values)
        for cpu, values in cpu_values.items()
        if cpu and values
    }
    busiest_cpu = max(median_cpu, key=median_cpu.get) if median_cpu else ""

    eth_irq = _sum_vectors(eth_irq_vectors)
    net_rx = _sum_vectors(net_rx_vectors)
    softnet = _sum_vectors(softnet_vectors)

    def dominant_share(values: list[int]) -> float:
        total = sum(values)
        return (max(values) / total) if total else 0.0

    queue_layout = queue_layouts[0] if queue_layouts else []
    return {
        "samples": len(rows),
        "median_mib_per_second": statistics.median(throughputs) if throughputs else 0.0,
        "net_queues": queue_layout,
        "rx_queue_count": sum(name.startswith("rx-") for name in queue_layout),
        "tx_queue_count": sum(name.startswith("tx-") for name in queue_layout),
        "median_cpu_utilization_percent": median_cpu,
        "busiest_cpu": busiest_cpu,
        "busiest_cpu_median_utilization_percent": median_cpu.get(busiest_cpu, 0.0),
        "eth_irq_per_cpu": eth_irq,
        "eth_irq_dominant_cpu_share": dominant_share(eth_irq),
        "net_rx_softirq_per_cpu": net_rx,
        "net_rx_dominant_cpu_share": dominant_share(net_rx),
        "softnet_processed_per_cpu": softnet,
        "softnet_dominant_cpu_share": dominant_share(softnet),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-a", default="container-runtime-linux")
    parser.add_argument("--runtime-b", default="container-runtime-krun")
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
    output = args.result_root / f"network-guest-cpu-compare-{token}"
    archive = args.result_root / f"container-runtime-krun-network-guest-cpu-compare-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    bench = streams_bench.Benchmark(output, args.timeout)
    prefix = f"krun-gcmp-{token.lower()}"
    label_a = f"apple-vz-guest-cpu{args.cpus}"
    label_b = f"krun-native-guest-cpu{args.cpus}"
    profiles: dict[str, list[dict[str, object]]] = {label_a: [], label_b: []}

    (output / "metadata.json").write_text(
        json.dumps(
            {
                "runtime_a": args.runtime_a,
                "runtime_b": args.runtime_b,
                "label_a": label_a,
                "label_b": label_b,
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
        endpoint_a = streams_bench.start_endpoint(
            bench,
            args.runtime_a,
            label_a,
            args.image,
            args.network,
            prefix,
            1,
            args.cpus,
        )
        profiles[label_a] = profile_endpoint(
            bench,
            endpoint_a,
            label_a,
            streams=args.streams,
            seconds=args.seconds,
            warmup_seconds=args.warmup_seconds,
            iterations=args.iterations,
            chunk_bytes=args.chunk_kib * 1024,
        )

        endpoint_b = streams_bench.start_endpoint(
            bench,
            args.runtime_b,
            label_b,
            args.image,
            args.network,
            prefix,
            2,
            args.cpus,
        )
        profiles[label_b] = profile_endpoint(
            bench,
            endpoint_b,
            label_b,
            streams=args.streams,
            seconds=args.seconds,
            warmup_seconds=args.warmup_seconds,
            iterations=args.iterations,
            chunk_bytes=args.chunk_kib * 1024,
        )

        summaries = {
            label_a: summarize_profile(profiles[label_a]),
            label_b: summarize_profile(profiles[label_b]),
        }
        a_throughput = float(summaries[label_a]["median_mib_per_second"])
        b_throughput = float(summaries[label_b]["median_mib_per_second"])
        comparison = {
            "profiles": summaries,
            "krun_over_apple_throughput_ratio": (b_throughput / a_throughput) if a_throughput else 0.0,
        }
        (output / "guest-cpu-comparison.json").write_text(
            json.dumps(comparison, indent=2) + "\n",
            encoding="utf-8",
        )
    except Exception as error:
        bench.failed = True
        bench.log(f"fatal guest CPU comparison error: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        for label, rows in profiles.items():
            (output / f"{label}-profile.json").write_text(
                json.dumps(rows, indent=2) + "\n",
                encoding="utf-8",
            )
        bench.cleanup()
        streams_bench.write_results(bench, label_a, label_b)
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if bench.failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
