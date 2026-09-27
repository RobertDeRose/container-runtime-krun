#!/usr/bin/env python3
"""Compare two P4 krun VMs on one native vmnet network vs two separate networks."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import tarfile
import threading
from datetime import datetime, timezone
from pathlib import Path

import benchmark_network_streams as streams_bench


def split_streams(total: int) -> int:
    if total < 2 or total % 2:
        raise argparse.ArgumentTypeError("streams must be an even integer >= 2")
    return total // 2


def aggregate_results(results: list[dict[str, object]], total_streams: int) -> dict[str, float | int]:
    if not results:
        raise ValueError("at least one result is required")
    byte_count = sum(int(result["bytes"]) for result in results)
    elapsed = max(float(result["elapsed_seconds"]) for result in results)
    completion_elapsed = max(float(result["completion_elapsed_seconds"]) for result in results)
    return {
        "bytes": byte_count,
        "elapsed_seconds": elapsed,
        "completion_elapsed_seconds": completion_elapsed,
        "mib_per_second": byte_count / streams_bench.MIB / elapsed,
        "streams": total_streams,
    }


def measure_group(
    bench: streams_bench.Benchmark,
    endpoints: list[streams_bench.Endpoint],
    streams_per_endpoint: int,
    total_streams: int,
    seconds: float,
    chunk_bytes: int,
    label: str,
) -> dict[str, float | int]:
    barrier = threading.Barrier(len(endpoints) + 1)
    lock = threading.Lock()
    results: list[dict[str, object]] = []
    errors: list[str] = []

    # Bind all host IPv4 addresses so VMs on distinct vmnet networks can use
    # their own gateway address while sharing one sink port.
    with streams_bench.SinkServer("0.0.0.0") as sink:
        def worker(index: int, endpoint: streams_bench.Endpoint) -> None:
            try:
                barrier.wait(timeout=30)
                result = streams_bench.guest_source(
                    bench,
                    endpoint,
                    endpoint.gateway,
                    sink.port,
                    streams_per_endpoint,
                    seconds,
                    chunk_bytes,
                    f"{label}-vm{index}",
                )
                with lock:
                    results.append(result)
            except Exception as error:
                with lock:
                    errors.append(repr(error))
                try:
                    barrier.abort()
                except Exception:
                    pass

        threads = [
            threading.Thread(target=worker, args=(index, endpoint))
            for index, endpoint in enumerate(endpoints, start=1)
        ]
        for thread in threads:
            thread.start()
        try:
            barrier.wait(timeout=30)
        except threading.BrokenBarrierError:
            pass
        for thread in threads:
            thread.join(timeout=max(30, seconds + 60))
        if any(thread.is_alive() for thread in threads):
            errors.append("group source worker did not terminate")
        if errors:
            raise RuntimeError("; ".join(errors))

    return aggregate_results(results, total_streams)


def create_network(bench: streams_bench.Benchmark, name: str, subnet: str, label: str) -> None:
    bench.run(
        label,
        [
            "container",
            "network",
            "create",
            "--subnet",
            subnet,
            "--option",
            "variant=allocationOnly",
            name,
        ],
    )


def delete_network(bench: streams_bench.Benchmark, name: str, label: str) -> None:
    try:
        result = subprocess.run(
            ["container", "network", "delete", name],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired:
        bench.failed = True
        bench.log(f"cleanup warning: network {name} delete timed out after 30 seconds")
        return
    (bench.output / f"{label}.txt").write_text(
        f"$ container network delete {name}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
        encoding="utf-8",
    )
    if result.returncode != 0:
        bench.failed = True
        bench.log(f"cleanup warning: network {name} delete exited with {result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", default="default", help="existing network for the shared-network pair")
    parser.add_argument("--subnet-a", default="172.29.250.0/24")
    parser.add_argument("--subnet-b", default="172.29.251.0/24")
    parser.add_argument("--image", default="python:3.13-alpine")
    parser.add_argument("--streams", type=int, default=8)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    try:
        split = split_streams(args.streams)
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))
    if args.cpus <= 0 or args.seconds <= 0 or args.warmup_seconds <= 0 or args.iterations <= 0:
        parser.error("cpus, seconds, warmup-seconds, and iterations must be positive")
    if args.chunk_kib <= 0:
        parser.error("chunk-kib must be positive")
    if args.subnet_a == args.subnet_b:
        parser.error("subnet-a and subnet-b must differ")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"network-network-scaling-{token}"
    archive = args.result_root / f"container-runtime-krun-network-network-scaling-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    bench = streams_bench.Benchmark(output, args.timeout)
    prefix = f"krun-netscale-{token.lower()}"
    same_label = "krun-native-two-vm-same-network-p4x2"
    split_label = "krun-native-two-vm-separate-networks-p4x2"
    net_a = f"kns-{os.getpid()}-a"
    net_b = f"kns-{os.getpid()}-b"
    created_networks: list[tuple[str, str]] = []

    (output / "metadata.json").write_text(
        json.dumps(
            {
                "same_network_label": same_label,
                "separate_networks_label": split_label,
                "runtime": "container-runtime-krun",
                "backend": "native",
                "cpus_per_vm": args.cpus,
                "streams_per_vm": split,
                "total_streams": args.streams,
                "seconds": args.seconds,
                "warmup_seconds": args.warmup_seconds,
                "iterations": args.iterations,
                "ordering": "odd iterations same/separate; even iterations separate/same",
                "shared_network": args.network,
                "separate_subnets": [args.subnet_a, args.subnet_b],
                "image": args.image,
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

    endpoints: list[streams_bench.Endpoint] = []
    try:
        create_network(bench, net_a, args.subnet_a, "network-a-create")
        created_networks.append((net_a, "network-a-delete"))
        create_network(bench, net_b, args.subnet_b, "network-b-create")
        created_networks.append((net_b, "network-b-delete"))

        same_a = streams_bench.start_endpoint(
            bench, "container-runtime-krun", f"{same_label}-a", args.image, args.network, prefix, 1, args.cpus
        )
        same_b = streams_bench.start_endpoint(
            bench, "container-runtime-krun", f"{same_label}-b", args.image, args.network, prefix, 2, args.cpus
        )
        split_a = streams_bench.start_endpoint(
            bench, "container-runtime-krun", f"{split_label}-a", args.image, net_a, prefix, 3, args.cpus
        )
        split_b = streams_bench.start_endpoint(
            bench, "container-runtime-krun", f"{split_label}-b", args.image, net_b, prefix, 4, args.cpus
        )
        endpoints.extend([same_a, same_b, split_a, split_b])

        bench.log(f"warmup {same_label} guest_to_host P{split}+P{split}")
        measure_group(
            bench, [same_a, same_b], split, args.streams, args.warmup_seconds,
            args.chunk_kib * 1024, f"{same_label}-warmup",
        )
        bench.log(f"warmup {split_label} guest_to_host P{split}+P{split}")
        measure_group(
            bench, [split_a, split_b], split, args.streams, args.warmup_seconds,
            args.chunk_kib * 1024, f"{split_label}-warmup",
        )

        def record(label: str, group: list[streams_bench.Endpoint], iteration: int) -> None:
            result = measure_group(
                bench, group, split, args.streams, args.seconds,
                args.chunk_kib * 1024, f"{label}-{iteration}",
            )
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

        for iteration in range(1, args.iterations + 1):
            if iteration % 2:
                record(same_label, [same_a, same_b], iteration)
                record(split_label, [split_a, split_b], iteration)
            else:
                record(split_label, [split_a, split_b], iteration)
                record(same_label, [same_a, same_b], iteration)
    except Exception as error:
        bench.failed = True
        bench.log(f"fatal benchmark error: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        bench.cleanup()
        for network, label in reversed(created_networks):
            delete_network(bench, network, label)
        streams_bench.write_results(bench, same_label, split_label)
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if bench.failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
