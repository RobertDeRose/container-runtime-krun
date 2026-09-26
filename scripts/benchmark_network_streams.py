#!/usr/bin/env python3
"""Benchmark sustained direct TCP throughput for Apple/VZ and krun runtimes."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import platform
import socket
import statistics
import struct
import subprocess
import sys
import tarfile
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

MIB = 1024 * 1024
GUEST_SINK_PORT = 8090
STREAM_TRAILER_MAGIC = b"\x00KRUN_STREAM_END\x00"
STREAM_TRAILER_LEN = len(STREAM_TRAILER_MAGIC) + 8

GUEST_SINK_SERVER = r'''
import socket
import struct
import threading
import time

PORT = int(__import__("sys").argv[1])
TRAILER_MAGIC = b"\x00KRUN_STREAM_END\x00"
TRAILER_LEN = len(TRAILER_MAGIC) + 8

def handle(conn):
    wire_bytes = 0
    tail = b""
    with conn:
        while True:
            data = conn.recv(256 * 1024)
            if not data:
                raise RuntimeError("source closed before stream trailer")
            wire_bytes += len(data)
            tail = (tail + data)[-TRAILER_LEN:]
            if len(tail) == TRAILER_LEN and tail.startswith(TRAILER_MAGIC):
                expected = struct.unpack("!Q", tail[len(TRAILER_MAGIC):])[0]
                received = wire_bytes - TRAILER_LEN
                if received != expected:
                    raise RuntimeError(
                        f"stream byte mismatch expected={expected} received={received}"
                    )
                conn.sendall(struct.pack("!Q", received))
                return

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", PORT))
server.listen(64)
print("READY", flush=True)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
'''

GUEST_SOURCE = r'''
import json
import socket
import struct
import sys
import threading
import time

host = sys.argv[1]
port = int(sys.argv[2])
streams = int(sys.argv[3])
seconds = float(sys.argv[4])
chunk_bytes = int(sys.argv[5])
chunk = b"s" * chunk_bytes
TRAILER_MAGIC = b"\x00KRUN_STREAM_END\x00"
state = {}
errors = []
results = []
lock = threading.Lock()

def arm():
    now = time.perf_counter_ns()
    state["start_ns"] = now
    state["deadline_ns"] = now + int(seconds * 1_000_000_000)

barrier = threading.Barrier(streams + 1, action=arm)

def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise RuntimeError("sink closed before byte-count acknowledgement")
        data.extend(part)
    return bytes(data)

def worker():
    sent = 0
    try:
        with socket.create_connection((host, port), timeout=30) as sock:
            sock.settimeout(30)
            barrier.wait(timeout=30)
            deadline = state["deadline_ns"]
            while time.perf_counter_ns() < deadline:
                sock.sendall(chunk)
                sent += len(chunk)
            send_end_ns = time.perf_counter_ns()
            sock.sendall(TRAILER_MAGIC + struct.pack("!Q", sent))
            received = struct.unpack("!Q", recv_exact(sock, 8))[0]
            if received != sent:
                raise RuntimeError(f"sink byte mismatch sent={sent} received={received}")
            completion_end_ns = time.perf_counter_ns()
        with lock:
            results.append((sent, send_end_ns, completion_end_ns))
    except Exception as error:
        with lock:
            errors.append(repr(error))
        try:
            barrier.abort()
        except Exception:
            pass

threads = [threading.Thread(target=worker) for _ in range(streams)]
for thread in threads:
    thread.start()
try:
    barrier.wait(timeout=30)
except threading.BrokenBarrierError:
    pass
for thread in threads:
    thread.join(timeout=max(30, seconds + 30))
if any(thread.is_alive() for thread in threads):
    errors.append("source worker did not terminate")
if errors:
    raise SystemExit("; ".join(errors))
byte_count = sum(item[0] for item in results)
send_end_ns = max(item[1] for item in results)
completion_end_ns = max(item[2] for item in results)
elapsed = (send_end_ns - state["start_ns"]) / 1_000_000_000
completion_elapsed = (completion_end_ns - state["start_ns"]) / 1_000_000_000
print(json.dumps({
    "bytes": byte_count,
    "elapsed_seconds": elapsed,
    "completion_elapsed_seconds": completion_elapsed,
    "mib_per_second": byte_count / (1024 * 1024) / elapsed,
    "streams": streams,
}, sort_keys=True))
'''


@dataclass(frozen=True)
class Endpoint:
    runtime: str
    container_id: str
    guest_ip: str
    gateway: str
    published_port: int


@dataclass(frozen=True)
class Sample:
    runtime: str
    direction: str
    streams: int
    iteration: int
    bytes: int
    elapsed_seconds: float
    completion_elapsed_seconds: float
    mib_per_second: float
    status: int


class SinkServer:
    def __init__(self, address: str, port: int = 0) -> None:
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((address, port))
        self.socket.listen(64)
        self.socket.settimeout(0.2)
        self.port = int(self.socket.getsockname()[1])
        self.stop_event = threading.Event()
        self.errors: list[str] = []
        self.workers: list[threading.Thread] = []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self.stop_event.is_set():
            try:
                conn, _ = self.socket.accept()
            except TimeoutError:
                continue
            except OSError:
                if self.stop_event.is_set():
                    return
                raise
            worker = threading.Thread(target=self._handle, args=(conn,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def _handle(self, conn: socket.socket) -> None:
        wire_bytes = 0
        tail = b""
        try:
            with conn:
                conn.settimeout(30)
                while True:
                    data = conn.recv(256 * 1024)
                    if not data:
                        raise RuntimeError("source closed before stream trailer")
                    wire_bytes += len(data)
                    tail = (tail + data)[-STREAM_TRAILER_LEN:]
                    if len(tail) == STREAM_TRAILER_LEN and tail.startswith(STREAM_TRAILER_MAGIC):
                        expected = struct.unpack("!Q", tail[len(STREAM_TRAILER_MAGIC):])[0]
                        received = wire_bytes - STREAM_TRAILER_LEN
                        if received != expected:
                            raise RuntimeError(
                                f"stream byte mismatch expected={expected} received={received}"
                            )
                        conn.sendall(struct.pack("!Q", received))
                        return
        except Exception as error:
            self.errors.append(repr(error))

    def close(self) -> None:
        self.stop_event.set()
        self.socket.close()
        self.thread.join(timeout=2)
        for worker in self.workers:
            worker.join(timeout=2)
        if self.errors:
            raise RuntimeError("host sink failure: " + "; ".join(self.errors))

    def __enter__(self) -> SinkServer:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


class Benchmark:
    def __init__(self, output: Path, timeout: int) -> None:
        self.output = output
        self.timeout = timeout
        self.output.mkdir(parents=True, exist_ok=True)
        self.active_containers: set[str] = set()
        self.samples: list[Sample] = []
        self.failed = False

    def log(self, message: str) -> None:
        print(f"[network-streams] {message}", flush=True)

    def run(
        self,
        label: str,
        argv: list[str],
        *,
        check: bool = True,
        timeout: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.log(f"RUN {label}: {' '.join(argv)}")
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout or self.timeout,
            check=False,
        )
        (self.output / f"{label}.txt").write_text(
            f"$ {' '.join(argv)}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
            encoding="utf-8",
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"{label} failed with exit {result.returncode}")
        return result

    def cleanup(self) -> None:
        for container_id in list(self.active_containers):
            subprocess.run(
                ["container", "delete", "--force", container_id],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
                check=False,
            )
            self.active_containers.discard(container_id)

    def record(self, sample: Sample) -> None:
        self.samples.append(sample)
        self.log(
            f"{sample.runtime} {sample.direction} P{sample.streams} #{sample.iteration}: "
            f"{sample.mib_per_second:.1f} MiB/s ({sample.elapsed_seconds:.3f}s send, "
            f"{sample.completion_elapsed_seconds:.3f}s complete)"
        )


def recv_exact(sock: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise RuntimeError("sink closed before byte-count acknowledgement")
        data.extend(part)
    return bytes(data)


def run_source(host: str, port: int, streams: int, seconds: float, chunk_bytes: int) -> dict[str, float | int]:
    if streams <= 0 or seconds <= 0 or chunk_bytes <= 0:
        raise ValueError("streams, seconds, and chunk_bytes must be positive")

    chunk = b"s" * chunk_bytes
    state: dict[str, int] = {}
    errors: list[str] = []
    results: list[tuple[int, int, int]] = []
    lock = threading.Lock()

    def arm() -> None:
        now = time.perf_counter_ns()
        state["start_ns"] = now
        state["deadline_ns"] = now + int(seconds * 1_000_000_000)

    barrier = threading.Barrier(streams + 1, action=arm)

    def worker() -> None:
        sent = 0
        try:
            with socket.create_connection((host, port), timeout=30) as sock:
                sock.settimeout(30)
                barrier.wait(timeout=30)
                deadline = state["deadline_ns"]
                while time.perf_counter_ns() < deadline:
                    sock.sendall(chunk)
                    sent += len(chunk)
                send_end_ns = time.perf_counter_ns()
                sock.sendall(STREAM_TRAILER_MAGIC + struct.pack("!Q", sent))
                received = struct.unpack("!Q", recv_exact(sock, 8))[0]
                if received != sent:
                    raise RuntimeError(f"sink byte mismatch sent={sent} received={received}")
                completion_end_ns = time.perf_counter_ns()
            with lock:
                results.append((sent, send_end_ns, completion_end_ns))
        except Exception as error:
            with lock:
                errors.append(repr(error))
            try:
                barrier.abort()
            except Exception:
                pass

    threads = [threading.Thread(target=worker) for _ in range(streams)]
    for thread in threads:
        thread.start()
    try:
        barrier.wait(timeout=30)
    except threading.BrokenBarrierError:
        pass
    for thread in threads:
        thread.join(timeout=max(30, seconds + 30))
    if any(thread.is_alive() for thread in threads):
        errors.append("source worker did not terminate")
    if errors:
        raise RuntimeError("; ".join(errors))

    byte_count = sum(item[0] for item in results)
    send_end_ns = max(item[1] for item in results)
    completion_end_ns = max(item[2] for item in results)
    elapsed = (send_end_ns - state["start_ns"]) / 1_000_000_000
    completion_elapsed = (completion_end_ns - state["start_ns"]) / 1_000_000_000
    return {
        "bytes": byte_count,
        "elapsed_seconds": elapsed,
        "completion_elapsed_seconds": completion_elapsed,
        "mib_per_second": byte_count / MIB / elapsed,
        "streams": streams,
    }


def parse_json_line(output: str) -> dict[str, object]:
    for line in reversed(output.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            value = json.loads(line)
            if isinstance(value, dict):
                return value
    raise ValueError("command did not emit a JSON result")


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def inspect_endpoint(bench: Benchmark, container_id: str) -> tuple[str, str]:
    deadline = time.monotonic() + 20
    last = ""
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["container", "inspect", container_id],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        last = result.stdout + result.stderr
        if result.returncode == 0:
            try:
                data = json.loads(result.stdout)
                attachments = data[0]["status"]["networks"]
                if attachments:
                    first = attachments[0]
                    guest_ip = str(ipaddress.IPv4Interface(first["ipv4Address"]).ip)
                    gateway = str(ipaddress.IPv4Address(first["ipv4Gateway"]))
                    return guest_ip, gateway
            except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError):
                pass
        time.sleep(0.2)
    (bench.output / f"{container_id}-inspect-error.txt").write_text(last, encoding="utf-8")
    raise RuntimeError(f"{container_id}: network attachment did not become ready")


def wait_ready(bench: Benchmark, container_id: str) -> None:
    deadline = time.monotonic() + 30
    last = ""
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["container", "logs", container_id],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        last = result.stdout + result.stderr
        if "READY" in last:
            return
        time.sleep(0.2)
    (bench.output / f"{container_id}-logs-not-ready.txt").write_text(last, encoding="utf-8")
    raise RuntimeError(f"{container_id}: guest sink did not become ready")


def start_endpoint(
    bench: Benchmark, runtime: str, label: str, image: str, network: str, prefix: str
) -> Endpoint:
    key = "".join(ch if ch.isalnum() else "-" for ch in label)
    container_id = f"{prefix}-{key}"
    published_port = free_tcp_port()
    bench.active_containers.add(container_id)
    bench.run(
        f"{key}-start",
        [
            "container", "run", "-d", "--name", container_id,
            "--runtime", runtime, "--network", network,
            "--publish", f"127.0.0.1:{published_port}:{GUEST_SINK_PORT}/tcp",
            image, "python3", "-u", "-c", GUEST_SINK_SERVER, str(GUEST_SINK_PORT),
        ],
    )
    wait_ready(bench, container_id)
    guest_ip, gateway = inspect_endpoint(bench, container_id)
    return Endpoint(label, container_id, guest_ip, gateway, published_port)



def configure_runtime_backend(marker: Path | None, backend: str) -> None:
    if backend == "default":
        return
    if marker is None:
        raise RuntimeError(f"backend {backend} requires --control-marker")
    if backend == "native":
        marker.unlink(missing_ok=True)
        return
    if backend == "vmnet-helper":
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("vmnet-helper-control-v1\n", encoding="utf-8")
        return
    raise ValueError(f"unsupported runtime backend {backend}")

def guest_source(
    bench: Benchmark,
    endpoint: Endpoint,
    host: str,
    port: int,
    streams: int,
    seconds: float,
    chunk_bytes: int,
    label: str,
) -> dict[str, object]:
    result = bench.run(
        label,
        [
            "container", "exec", endpoint.container_id,
            "python3", "-c", GUEST_SOURCE,
            host, str(port), str(streams), str(seconds), str(chunk_bytes),
        ],
        timeout=max(bench.timeout, int(seconds) + 60),
    )
    return parse_json_line(result.stdout)


def run_direction(
    bench: Benchmark,
    endpoints: list[Endpoint],
    direction: str,
    streams: int,
    seconds: float,
    warmup_seconds: float,
    iterations: int,
    chunk_bytes: int,
) -> None:
    def measure(endpoint: Endpoint, duration: float, label: str) -> dict[str, object]:
        if direction == "host_to_guest":
            result = run_source("127.0.0.1", endpoint.published_port, streams, duration, chunk_bytes)
            (bench.output / f"{label}.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            return result
        if direction == "guest_to_host":
            with SinkServer(endpoint.gateway) as sink:
                return guest_source(
                    bench, endpoint, endpoint.gateway, sink.port, streams, duration, chunk_bytes, label
                )
        raise ValueError(f"unsupported direction {direction}")

    for endpoint in endpoints:
        key = "".join(ch if ch.isalnum() else "-" for ch in endpoint.runtime)
        bench.log(f"warmup {endpoint.runtime} {direction} P{streams}")
        measure(endpoint, warmup_seconds, f"{key}-{direction}-p{streams}-warmup")

    for iteration in range(1, iterations + 1):
        order = endpoints if iteration % 2 else list(reversed(endpoints))
        for endpoint in order:
            key = "".join(ch if ch.isalnum() else "-" for ch in endpoint.runtime)
            try:
                result = measure(
                    endpoint,
                    seconds,
                    f"{key}-{direction}-p{streams}-{iteration}",
                )
                sample = Sample(
                    runtime=endpoint.runtime,
                    direction=direction,
                    streams=streams,
                    iteration=iteration,
                    bytes=int(result["bytes"]),
                    elapsed_seconds=float(result["elapsed_seconds"]),
                    completion_elapsed_seconds=float(result["completion_elapsed_seconds"]),
                    mib_per_second=float(result["mib_per_second"]),
                    status=0,
                )
            except Exception as error:
                bench.failed = True
                bench.log(f"{endpoint.runtime} {direction} P{streams} #{iteration} failed: {error}")
                sample = Sample(endpoint.runtime, direction, streams, iteration, 0, 0.0, 0.0, 0.0, 1)
            bench.record(sample)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise ValueError("cannot calculate percentile of empty values")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def summarize(samples: list[Sample]) -> list[dict[str, object]]:
    groups: dict[tuple[str, str, int], list[Sample]] = {}
    for sample in samples:
        if sample.status == 0:
            groups.setdefault((sample.runtime, sample.direction, sample.streams), []).append(sample)
    rows: list[dict[str, object]] = []
    for (runtime, direction, streams), group in sorted(groups.items()):
        rates = [sample.mib_per_second for sample in group]
        completion_overheads_ms = [
            max(0.0, sample.completion_elapsed_seconds - sample.elapsed_seconds) * 1000
            for sample in group
        ]
        rows.append({
            "runtime": runtime,
            "direction": direction,
            "streams": streams,
            "samples": len(rates),
            "median_mib_per_second": statistics.median(rates),
            "p10_mib_per_second": percentile(rates, 0.10),
            "p90_mib_per_second": percentile(rates, 0.90),
            "min_mib_per_second": min(rates),
            "max_mib_per_second": max(rates),
            "median_completion_overhead_ms": statistics.median(completion_overheads_ms),
        })
    return rows


def paired_ratios(
    samples: list[Sample],
    runtime_a: str,
    runtime_b: str,
    direction: str,
    streams: int,
) -> list[float]:
    successful = {
        (sample.runtime, sample.iteration): sample
        for sample in samples
        if sample.status == 0 and sample.direction == direction and sample.streams == streams
    }
    iterations = sorted({
        iteration
        for runtime, iteration in successful
        if runtime == runtime_a and (runtime_b, iteration) in successful
    })
    return [
        successful[(runtime_b, iteration)].mib_per_second
        / successful[(runtime_a, iteration)].mib_per_second
        for iteration in iterations
        if successful[(runtime_a, iteration)].mib_per_second > 0
    ]


def write_results(bench: Benchmark, runtime_a: str, runtime_b: str) -> None:
    samples_path = bench.output / "samples.tsv"
    with samples_path.open("w", encoding="utf-8") as stream:
        stream.write(
            "runtime\tdirection\tstreams\titeration\tbytes\telapsed_seconds\t"
            "completion_elapsed_seconds\tmib_per_second\tstatus\n"
        )
        for sample in bench.samples:
            stream.write(
                f"{sample.runtime}\t{sample.direction}\t{sample.streams}\t{sample.iteration}\t"
                f"{sample.bytes}\t{sample.elapsed_seconds:.6f}\t{sample.completion_elapsed_seconds:.6f}\t"
                f"{sample.mib_per_second:.3f}\t{sample.status}\n"
            )

    rows = summarize(bench.samples)
    (bench.output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    with (bench.output / "summary.tsv").open("w", encoding="utf-8") as stream:
        stream.write(
            "runtime\tdirection\tstreams\tsamples\tmedian_mib_per_second\tp10_mib_per_second\t"
            "p90_mib_per_second\tmin_mib_per_second\tmax_mib_per_second\t"
            "median_completion_overhead_ms\n"
        )
        for row in rows:
            stream.write(
                f"{row['runtime']}\t{row['direction']}\t{row['streams']}\t{row['samples']}\t"
                f"{row['median_mib_per_second']:.3f}\t{row['p10_mib_per_second']:.3f}\t"
                f"{row['p90_mib_per_second']:.3f}\t{row['min_mib_per_second']:.3f}\t"
                f"{row['max_mib_per_second']:.3f}\t{row['median_completion_overhead_ms']:.3f}\n"
            )

    by_key = {(row["runtime"], row["direction"], row["streams"]): row for row in rows}
    comparison: list[dict[str, object]] = []
    for direction in ("guest_to_host", "host_to_guest"):
        for streams in sorted({sample.streams for sample in bench.samples}):
            a = by_key.get((runtime_a, direction, streams))
            b = by_key.get((runtime_b, direction, streams))
            if not a or not b:
                continue
            a_median = float(a["median_mib_per_second"])
            b_median = float(b["median_mib_per_second"])
            ratios = paired_ratios(bench.samples, runtime_a, runtime_b, direction, streams)
            comparison.append({
                "direction": direction,
                "streams": streams,
                "runtime_a": runtime_a,
                "runtime_a_median_mib_per_second": a_median,
                "runtime_b": runtime_b,
                "runtime_b_median_mib_per_second": b_median,
                "runtime_b_over_a": b_median / a_median if a_median else 0.0,
                "paired_samples": len(ratios),
                "median_paired_b_over_a": statistics.median(ratios) if ratios else 0.0,
                "p10_paired_b_over_a": percentile(ratios, 0.10) if ratios else 0.0,
                "p90_paired_b_over_a": percentile(ratios, 0.90) if ratios else 0.0,
            })
    (bench.output / "comparison.json").write_text(json.dumps(comparison, indent=2) + "\n", encoding="utf-8")
    with (bench.output / "comparison.tsv").open("w", encoding="utf-8") as stream:
        stream.write(
            "direction\tstreams\truntime_a\truntime_a_median_mib_per_second\t"
            "runtime_b\truntime_b_median_mib_per_second\truntime_b_over_a\tpaired_samples\t"
            "median_paired_b_over_a\tp10_paired_b_over_a\tp90_paired_b_over_a\n"
        )
        for row in comparison:
            stream.write(
                f"{row['direction']}\t{row['streams']}\t{row['runtime_a']}\t"
                f"{row['runtime_a_median_mib_per_second']:.3f}\t{row['runtime_b']}\t"
                f"{row['runtime_b_median_mib_per_second']:.3f}\t{row['runtime_b_over_a']:.4f}\t"
                f"{row['paired_samples']}\t{row['median_paired_b_over_a']:.4f}\t"
                f"{row['p10_paired_b_over_a']:.4f}\t{row['p90_paired_b_over_a']:.4f}\n"
            )



def git_head(path: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None

def parse_streams(value: str) -> list[int]:
    try:
        streams = [int(item.strip()) for item in value.split(",") if item.strip()]
    except ValueError as error:
        raise argparse.ArgumentTypeError("streams must be comma-separated positive integers") from error
    if not streams or any(item <= 0 for item in streams):
        raise argparse.ArgumentTypeError("streams must be comma-separated positive integers")
    return streams


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-a", default="container-runtime-linux")
    parser.add_argument("--runtime-b", default="container-runtime-krun")
    parser.add_argument("--runtime-a-label")
    parser.add_argument("--runtime-b-label")
    parser.add_argument(
        "--runtime-a-backend", choices=("default", "native", "vmnet-helper"), default="default"
    )
    parser.add_argument(
        "--runtime-b-backend", choices=("default", "native", "vmnet-helper"), default="default"
    )
    parser.add_argument("--control-marker", type=Path)
    parser.add_argument("--network", default="default")
    parser.add_argument("--image", default="python:3.13-alpine")
    parser.add_argument("--streams", type=parse_streams, default=parse_streams("1,4,8"))
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--warmup-seconds", type=float, default=1.0)
    parser.add_argument("--iterations", type=int, default=4)
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    if args.seconds <= 0 or args.warmup_seconds <= 0 or args.iterations <= 0 or args.chunk_kib <= 0:
        parser.error("seconds, warmup-seconds, iterations, and chunk-kib must be positive")

    runtime_a_label = args.runtime_a_label or args.runtime_a
    runtime_b_label = args.runtime_b_label or args.runtime_b
    if runtime_a_label == runtime_b_label:
        parser.error("runtime labels must be distinct")
    if (args.runtime_a_backend != "default" or args.runtime_b_backend != "default") and args.control_marker is None:
        parser.error("non-default runtime backends require --control-marker")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"network-streams-{token}"
    archive = args.result_root / f"container-runtime-krun-network-streams-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    bench = Benchmark(output, args.timeout)
    endpoints: list[Endpoint] = []
    prefix = f"krun-streams-{token.lower()}"

    (output / "metadata.json").write_text(json.dumps({
        "runtime_a": args.runtime_a,
        "runtime_a_label": runtime_a_label,
        "runtime_a_backend": args.runtime_a_backend,
        "runtime_b": args.runtime_b,
        "runtime_b_label": runtime_b_label,
        "runtime_b_backend": args.runtime_b_backend,
        "control_marker": str(args.control_marker) if args.control_marker else None,
        "network": args.network,
        "image": args.image,
        "streams": args.streams,
        "seconds": args.seconds,
        "warmup_seconds": args.warmup_seconds,
        "iterations": args.iterations,
        "ordering": "odd iterations A/B; even iterations B/A",
        "guest_to_host_transport": "guest to host gateway listener",
        "host_to_guest_transport": "published TCP port to guest sink",
        "chunk_kib": args.chunk_kib,
        "repository_head": git_head(Path.cwd()),
        "libkrun_head": git_head(Path(".build-deps/libkrun")),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }, indent=2) + "\n", encoding="utf-8")

    try:
        runtime_specs = (
            (args.runtime_a, runtime_a_label, args.runtime_a_backend),
            (args.runtime_b, runtime_b_label, args.runtime_b_backend),
        )
        for runtime, label, backend in runtime_specs:
            configure_runtime_backend(args.control_marker, backend)
            endpoints.append(start_endpoint(bench, runtime, label, args.image, args.network, prefix))
        if args.control_marker is not None:
            args.control_marker.unlink(missing_ok=True)

        for streams in args.streams:
            run_direction(
                bench, endpoints, "guest_to_host", streams, args.seconds,
                args.warmup_seconds, args.iterations, args.chunk_kib * 1024,
            )
            run_direction(
                bench, endpoints, "host_to_guest", streams, args.seconds,
                args.warmup_seconds, args.iterations, args.chunk_kib * 1024,
            )
    except Exception as error:
        bench.failed = True
        bench.log(f"fatal benchmark error: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        bench.cleanup()
        if args.control_marker is not None:
            args.control_marker.unlink(missing_ok=True)
        write_results(bench, runtime_a_label, runtime_b_label)
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if bench.failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
