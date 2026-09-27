#!/usr/bin/env python3
"""Compare one P8 krun VM with two concurrent P4 krun VMs on native vmnet."""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import tarfile
import threading
import time
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
    gateways = {endpoint.gateway for endpoint in endpoints}
    if len(gateways) != 1:
        raise RuntimeError(f"group endpoints use different gateways: {sorted(gateways)}")

    barrier = threading.Barrier(len(endpoints) + 1)
    lock = threading.Lock()
    results: list[dict[str, object]] = []
    errors: list[str] = []

    with streams_bench.SinkServer(endpoints[0].gateway) as sink:
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


def percentile(values: list[float], quantile: float) -> float:
    return streams_bench.percentile(values, quantile)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", default="default")
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

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"network-worker-scaling-{token}"
    archive = args.result_root / f"container-runtime-krun-network-worker-scaling-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    bench = streams_bench.Benchmark(output, args.timeout)
    prefix = f"krun-worker-{token.lower()}"
    single_label = "krun-native-one-vm-p8"
    dual_label = "krun-native-two-vm-p4x2"

    (output / "metadata.json").write_text(
        json.dumps(
            {
                "single_label": single_label,
                "dual_label": dual_label,
                "runtime": "container-runtime-krun",
                "backend": "native",
                "cpus_per_vm": args.cpus,
                "single_vm_streams": args.streams,
                "dual_vm_streams_per_vm": split,
                "seconds": args.seconds,
                "warmup_seconds": args.warmup_seconds,
                "iterations": args.iterations,
                "ordering": "odd iterations one/two VMs; even iterations two/one VMs",
                "network": args.network,
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
        single = streams_bench.start_endpoint(
            bench,
            "container-runtime-krun",
            single_label,
            args.image,
            args.network,
            prefix,
            1,
            args.cpus,
        )
        dual_a = streams_bench.start_endpoint(
            bench,
            "container-runtime-krun",
            f"{dual_label}-a",
            args.image,
            args.network,
            prefix,
            2,
            args.cpus,
        )
        dual_b = streams_bench.start_endpoint(
            bench,
            "container-runtime-krun",
            f"{dual_label}-b",
            args.image,
            args.network,
            prefix,
            3,
            args.cpus,
        )
        endpoints.extend([single, dual_a, dual_b])

        bench.log(f"warmup {single_label} guest_to_host P{args.streams}")
        measure_group(
            bench,
            [single],
            args.streams,
            args.streams,
            args.warmup_seconds,
            args.chunk_kib * 1024,
            f"{single_label}-warmup",
        )
        bench.log(f"warmup {dual_label} guest_to_host P{split}+P{split}")
        measure_group(
            bench,
            [dual_a, dual_b],
            split,
            args.streams,
            args.warmup_seconds,
            args.chunk_kib * 1024,
            f"{dual_label}-warmup",
        )

        def record(label: str, group: list[streams_bench.Endpoint], per_vm_streams: int, iteration: int) -> None:
            result = measure_group(
                bench,
                group,
                per_vm_streams,
                args.streams,
                args.seconds,
                args.chunk_kib * 1024,
                f"{label}-{iteration}",
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
                record(single_label, [single], args.streams, iteration)
                record(dual_label, [dual_a, dual_b], split, iteration)
            else:
                record(dual_label, [dual_a, dual_b], split, iteration)
                record(single_label, [single], args.streams, iteration)
    except Exception as error:
        bench.failed = True
        bench.log(f"fatal benchmark error: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        bench.cleanup()
        streams_bench.write_results(bench, single_label, dual_label)
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if bench.failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
