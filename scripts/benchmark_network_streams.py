#!/usr/bin/env python3
"""Benchmark sustained direct TCP throughput for Apple/VZ and krun runtimes."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import platform
import shlex
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
from pathlib import Path
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
tcp_interval_ms = int(sys.argv[6]) if len(sys.argv) > 6 else 0
tcp_congestion = sys.argv[7] if len(sys.argv) > 7 else "default"
if tcp_interval_ms != 0 and tcp_interval_ms < 100:
    raise SystemExit("TCP sampling interval must be zero or at least 100 ms")
chunk = b"s" * chunk_bytes
TRAILER_MAGIC = b"\x00KRUN_STREAM_END\x00"
state = {}
errors = []
failures = []
failure_network = {}
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

def record_failure(stream_id, phase, sent, sock, error):
    # Called only after an operation fails, while the socket is still open.
    # sent counts completed sendall calls; a failing call may have sent more.
    failure = {
        "stream_id": stream_id,
        "phase": phase,
        "completed_send_bytes": sent,
        "error": repr(error),
        "elapsed_seconds": (
            (time.perf_counter_ns() - state["start_ns"]) / 1_000_000_000
            if "start_ns" in state else None
        ),
    }
    if sock is not None:
        for key, read in (
            ("local_address", sock.getsockname),
            ("peer_address", sock.getpeername),
            ("tcp_info_hex", lambda: sock.getsockopt(
                socket.IPPROTO_TCP, socket.TCP_INFO, 256,
            ).hex()),
        ):
            try:
                failure[key] = read()
            except Exception as detail_error:
                failure[key] = {"error": repr(detail_error)}
    with lock:
        failures.append(failure)
        if not failure_network:
            for name in ("tcp", "snmp", "netstat"):
                try:
                    failure_network[name] = Path("/proc/net", name).read_text()
                except OSError as read_error:
                    failure_network[name] = "ERROR: " + repr(read_error)


# Opt-in, read-only sampling. The sender's per-chunk loop is unchanged.
# One sampler handles all streams; the lock only protects setup/teardown
# and infrequent getsockopt calls, never payload transmission.
tcp_lock = threading.Lock()
tcp_stop = threading.Event()
tcp_active = {}
tcp_flows = {}
tcp_sample_errors = []
tcp_congestion_flows = {}

def tcp_snapshot(sock, phase):
    started = time.perf_counter_ns()
    raw = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_INFO, 256)
    finished = time.perf_counter_ns()
    # TCP_CC_INFO (26): the congestion control's own state, e.g. BBR's
    # bandwidth and min RTT estimates. Not every algorithm provides it.
    try:
        cc_info = sock.getsockopt(socket.IPPROTO_TCP, 26, 64).hex()
    except OSError:
        cc_info = None
    return {
        "phase": phase,
        "elapsed_seconds": (
            (started - state["start_ns"]) / 1_000_000_000
            if "start_ns" in state else None
        ),
        "getsockopt_ns": finished - started,
        "tcp_info_hex": raw.hex(),
        "tcp_cc_info_hex": cc_info,
    }

def tcp_register(stream_id, sock):
    # Fail explicitly before sending if the requested socket API is absent.
    row = {
        "stream_id": stream_id,
        "local_address": sock.getsockname(),
        "peer_address": sock.getpeername(),
        "congestion_control": sock.getsockopt(
            socket.IPPROTO_TCP, socket.TCP_CONGESTION, 64,
        ).split(b"\0", 1)[0].decode("ascii", errors="replace"),
        "send_buffer_bytes": sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF),
        "snapshots": [tcp_snapshot(sock, "connected")],
    }
    with tcp_lock:
        tcp_flows[stream_id] = row
        tcp_active[stream_id] = (sock, "sending")

def tcp_boundary(stream_id, phase, *, finished=False):
    with tcp_lock:
        active = tcp_active.get(stream_id)
        if active is None:
            return
        sock, _ = active
        try:
            tcp_flows[stream_id]["snapshots"].append(tcp_snapshot(sock, phase))
        except Exception as error:
            tcp_sample_errors.append({"stream_id": stream_id, "error": repr(error)})
        if finished:
            del tcp_active[stream_id]
        else:
            tcp_active[stream_id] = (sock, "finishing")

def sample_tcp_flows():
    while not tcp_stop.wait(tcp_interval_ms / 1000):
        with tcp_lock:
            for stream_id, (sock, phase) in tcp_active.items():
                try:
                    tcp_flows[stream_id]["snapshots"].append(tcp_snapshot(sock, phase))
                except Exception as error:
                    tcp_sample_errors.append({"stream_id": stream_id, "error": repr(error)})


def source_connection(stream_id):
    # Leave the default connection path untouched. An override applies only to
    # this sender socket, before connect; never change a guest/host sysctl.
    if tcp_congestion == "default":
        return socket.create_connection((host, port), timeout=30)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.settimeout(30)
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION,
                            tcp_congestion.encode("ascii"))
            actual = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, 64)
            actual = actual.split(b"\0", 1)[0].decode("ascii")
        except OSError as error:
            try:
                available = Path("/proc/sys/net/ipv4/tcp_available_congestion_control").read_text().strip()
            except OSError:
                available = "unavailable"
            raise RuntimeError(
                f"cannot select TCP_CONGESTION={tcp_congestion!r}: {error}; "
                f"registered algorithms: {available}; no fallback was used"
            ) from error
        if actual != tcp_congestion:
            raise RuntimeError(f"requested TCP_CONGESTION={tcp_congestion!r}, got {actual!r}")
        sock.connect((host, port))
        with lock:
            tcp_congestion_flows[stream_id] = {"stream_id": stream_id, "algorithm": actual}
        return sock
    except BaseException:
        sock.close()
        raise


def worker(stream_id):
    sent = 0
    phase = "connect"
    recorded = False
    try:
        with source_connection(stream_id) as sock:
            try:
                sock.settimeout(30)
                if tcp_interval_ms:
                    phase = "tcp_profile_setup"
                    tcp_register(stream_id, sock)
                phase = "start_barrier"
                barrier.wait(timeout=30)
                deadline = state["deadline_ns"]
                phase = "send_payload"
                while time.perf_counter_ns() < deadline:
                    sock.sendall(chunk)
                    sent += len(chunk)
                send_end_ns = time.perf_counter_ns()
                if tcp_interval_ms:
                    tcp_boundary(stream_id, "payload_end")
                phase = "send_trailer"
                sock.sendall(TRAILER_MAGIC + struct.pack("!Q", sent))
                phase = "receive_ack"
                received = struct.unpack("!Q", recv_exact(sock, 8))[0]
                if received != sent:
                    raise RuntimeError(f"sink byte mismatch sent={sent} received={received}")
                completion_end_ns = time.perf_counter_ns()
                phase = "complete"
            except Exception as error:
                record_failure(stream_id, phase, sent, sock, error)
                recorded = True
                raise
            finally:
                if tcp_interval_ms:
                    tcp_boundary(stream_id, phase, finished=True)
        with lock:
            results.append((sent, send_end_ns, completion_end_ns))
    except Exception as error:
        if not recorded:
            record_failure(stream_id, phase, sent, None, error)
        with lock:
            errors.append(repr(error))
        try:
            barrier.abort()
        except Exception:
            pass

threads = [threading.Thread(target=worker, args=(index,)) for index in range(streams)]
for thread in threads:
    thread.start()
tcp_sampler = None
try:
    barrier.wait(timeout=30)
    if tcp_interval_ms:
        tcp_sampler = threading.Thread(target=sample_tcp_flows, daemon=True)
        tcp_sampler.start()
except threading.BrokenBarrierError:
    pass
for thread in threads:
    thread.join(timeout=max(30, seconds + 30))
if any(thread.is_alive() for thread in threads):
    errors.append("source worker did not terminate")
tcp_stop.set()
if tcp_sampler is not None:
    tcp_sampler.join(timeout=5)
    if tcp_sampler.is_alive():
        errors.append("TCP sampler did not terminate")
tcp_congestion_evidence = {
    "requested": tcp_congestion,
    "flows": [tcp_congestion_flows[key] for key in sorted(tcp_congestion_flows)],
} if tcp_congestion != "default" else None
tcp_evidence = None
if tcp_interval_ms:
    with tcp_lock:
        tcp_evidence = {
            "schema_version": 1,
            "interval_ms": tcp_interval_ms,
            "byteorder": sys.byteorder,
            "guest_kernel": __import__("os").uname().release,
            "flows": [tcp_flows[key] for key in sorted(tcp_flows)],
            "errors": list(tcp_sample_errors),
        }
if errors:
    print("KRUN_STREAM_FAILURE " + json.dumps({
        "streams": sorted(failures, key=lambda row: row["stream_id"]),
        "network_at_first_failure": failure_network,
        "errors": errors,
        **({"tcp_flow": tcp_evidence} if tcp_interval_ms else {}),
        **({"tcp_congestion": tcp_congestion_evidence} if tcp_congestion_evidence else {}),
    }, sort_keys=True), file=sys.stderr, flush=True)
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
    **({"tcp_flow": tcp_evidence} if tcp_interval_ms else {}),
    **({"tcp_congestion": tcp_congestion_evidence} if tcp_congestion_evidence else {}),
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
    def __init__(self, address: str, port: int = 0, *, evidence_path: Path | None = None) -> None:
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((address, port))
        self.socket.listen(64)
        self.socket.settimeout(0.2)
        self.port = int(self.socket.getsockname()[1])
        self.stop_event = threading.Event()
        self.errors: list[str] = []
        self.connections: list[dict[str, object]] = []
        self.results_lock = threading.Lock()
        self.evidence_path = evidence_path
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
        record: dict[str, object] = {"phase": "receive_payload", "ack_sent": False}
        try:
            with conn:
                record["local_address"] = conn.getsockname()
                record["peer_address"] = conn.getpeername()
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
                        record["expected_payload_bytes"] = expected
                        record["received_payload_bytes"] = received
                        if received != expected:
                            raise RuntimeError(
                                f"stream byte mismatch expected={expected} received={received}"
                            )
                        record["phase"] = "send_ack"
                        conn.sendall(struct.pack("!Q", received))
                        record["ack_sent"] = True
                        record["phase"] = "complete"
                        return
        except Exception as error:
            record["error"] = repr(error)
        finally:
            # Publish once per connection, never once per received chunk.
            record["wire_bytes"] = wire_bytes
            with self.results_lock:
                self.connections.append(record)
                if "error" in record:
                    self.errors.append(str(record["error"]))

    def close(self) -> None:
        self.stop_event.set()
        # _serve exits within one accept timeout. Drain the listen backlog before
        # closing so a source that connected and failed still leaves a record.
        self.thread.join(timeout=2)
        if not self.thread.is_alive():
            self.socket.setblocking(False)
            while True:
                try:
                    conn, _ = self.socket.accept()
                except OSError:
                    break
                conn.setblocking(True)
                worker = threading.Thread(target=self._handle, args=(conn,), daemon=True)
                self.workers.append(worker)
                worker.start()
        self.socket.close()
        for worker in list(self.workers):
            worker.join(timeout=2)
        if self.errors:
            raise RuntimeError("host sink failure: " + "; ".join(self.errors))

    def __enter__(self) -> SinkServer:
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        close_error = None
        try:
            self.close()
        except Exception as error:
            close_error = error
        if self.evidence_path is not None:
            with self.results_lock:
                evidence = {
                    "connections": list(self.connections),
                    "errors": list(self.errors),
                    "unfinished_workers": sum(worker.is_alive() for worker in self.workers),
                    "primary_error": repr(exc) if exc is not None else None,
                    "close_error": repr(close_error) if close_error is not None else None,
                }
            try:
                self.evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
            except OSError as error:
                print(f"[network-streams] could not save host sink evidence: {error}", file=sys.stderr)
        if close_error is not None:
            if exc is None:
                raise close_error
            # A reset during timeout cleanup must not replace the source error.
            print(f"[network-streams] additional host sink failure: {close_error}", file=sys.stderr)


class Benchmark:
    def __init__(self, output: Path, timeout: int) -> None:
        self.output = output
        self.timeout = timeout
        self.output.mkdir(parents=True, exist_ok=True)
        self.active_containers: set[str] = set()
        self.samples: list[Sample] = []
        self.failed = False
        self.tcp_info_interval_ms = 0
        self.tcp_congestion = "default"
        # Optional guest preparation for experiments: capabilities granted to the
        # endpoint and a shell command run in it once it is ready.
        self.guest_cap_add: list[str] = []
        self.guest_setup: str | None = None

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
        command = shlex.join(argv)
        self.log(f"RUN {label}: {command}")
        log_path = self.output / f"{label}.txt"
        try:
            result = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=timeout or self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            # TimeoutExpired can carry bytes even when text=True.
            stdout = error.stdout or ""
            stderr = error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            log_path.write_text(
                f"$ {command}\n{stdout}{stderr}\ntimeout_seconds={error.timeout}\n",
                encoding="utf-8",
            )
            raise
        except OSError as error:
            log_path.write_text(f"$ {command}\nlaunch_error={error!r}\n", encoding="utf-8")
            raise
        log_path.write_text(
            f"$ {command}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
            encoding="utf-8",
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"{label} failed with exit {result.returncode}")
        return result

    def cleanup(self) -> None:
        cleanup_errors: list[str] = []
        for container_id in list(self.active_containers):
            try:
                result = self.run(
                    f"{container_id}-delete",
                    ["container", "delete", "--force", container_id],
                    timeout=30,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                cleanup_errors.append(f"{container_id}: delete --force timed out after 30 seconds")
                continue
            except OSError as error:
                cleanup_errors.append(f"{container_id}: delete --force could not run: {error}")
                continue
            if result.returncode != 0:
                cleanup_errors.append(
                    f"{container_id}: delete --force exited with {result.returncode}"
                )
                continue
            self.active_containers.discard(container_id)

        if cleanup_errors:
            self.failed = True
            for error in cleanup_errors:
                self.log(f"cleanup warning: {error}")
            (self.output / "cleanup-errors.txt").write_text(
                "\n".join(cleanup_errors) + "\n", encoding="utf-8"
            )

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
                    (bench.output / f"{container_id}-inspect.txt").write_text(last, encoding="utf-8")
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
    bench: Benchmark,
    runtime: str,
    label: str,
    image: str,
    network: str,
    prefix: str,
    slot: int,
    cpus: int | None = None,
) -> Endpoint:
    key = "".join(ch if ch.isalnum() else "-" for ch in label)
    container_id = f"{prefix}-r{slot}"
    published_port = free_tcp_port()
    bench.active_containers.add(container_id)
    command = [
        "container", "run", "-d", "--name", container_id,
        "--runtime", runtime, "--network", network,
    ]
    if cpus is not None:
        command.extend(["--cpus", str(cpus)])
    for capability in bench.guest_cap_add:
        command.extend(["--cap-add", capability])
    command.extend([
        "--publish", f"127.0.0.1:{published_port}:{GUEST_SINK_PORT}/tcp",
        image, "python3", "-u", "-c", GUEST_SINK_SERVER, str(GUEST_SINK_PORT),
    ])
    bench.run(f"{key}-start", command)
    wait_ready(bench, container_id)
    if bench.guest_setup:
        # Recorded per endpoint; a failed setup fails the run rather than
        # silently measuring an unprepared guest.
        bench.run(f"{key}-guest-setup", ["container", "exec", container_id, "sh", "-c", bench.guest_setup])
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

def capture_guest_network_failure(
    bench: Benchmark,
    endpoint: Endpoint,
    host: str,
    port: int,
    label: str,
) -> None:
    """Capture read-only evidence before the host listener and guest are removed."""
    prefix = f"{label}-network"
    (bench.output / f"{prefix}.json").write_text(
        json.dumps(
            {"endpoint": asdict(endpoint), "target_host": host, "target_port": port},
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    guest_commands = (
        'set -x\n'
        'ip -4 address show\n'
        'ip -4 route show\n'
        'ip -4 route get "$1"\n'
        'ip neigh show\n'
        'cat /proc/net/arp\n'
        'cat /proc/net/dev\n'
    )
    commands = [
        ("inspect", ["container", "inspect", endpoint.container_id]),
        ("guest", ["container", "exec", endpoint.container_id,
                   "sh", "-c", guest_commands, "network-diagnostics", host]),
        ("host-interfaces", ["/sbin/ifconfig", "-a"]),
        ("host-routes", ["/usr/sbin/netstat", "-rn", "-f", "inet"]),
        ("host-route-to-guest", ["/sbin/route", "-n", "get", endpoint.guest_ip]),
        ("host-neighbors", ["/usr/sbin/arp", "-an"]),
        ("host-listener", ["/usr/sbin/lsof", "-nP", "-a", f"-iTCP:{port}", "-sTCP:LISTEN"]),
        ("guest-logs", ["container", "logs", endpoint.container_id]),
    ]
    for suffix, command in commands:
        try:
            bench.run(f"{prefix}-{suffix}", command, check=False, timeout=10)
        except Exception as error:
            # A missing tool or unresponsive guest must not hide the transfer failure.
            bench.log(f"network diagnostic {suffix} failed: {error}")


# Linux UAPI struct tcp_info: fixed native-endian fields, not the host's
# (macOS) TCP_CONNECTION_INFO layout. Each tail field is length-checked.
# See include/uapi/linux/tcp.h in the Linux source. Values use UAPI units:
# rtt/rttvar/min_rtt and *_time/*_limited are microseconds; rates are B/s;
# snd_cwnd/unacked/sacked/lost/retrans are segments; *_wnd are bytes.
TCP_INFO_FIELDS = {
    "tcpi_state": (0, 1), "tcpi_ca_state": (1, 1),
    "tcpi_snd_mss": (16, 4), "tcpi_unacked": (24, 4),
    "tcpi_sacked": (28, 4), "tcpi_lost": (32, 4), "tcpi_retrans": (36, 4),
    "tcpi_rtt": (68, 4), "tcpi_rttvar": (72, 4),
    "tcpi_snd_ssthresh": (76, 4), "tcpi_snd_cwnd": (80, 4),
    "tcpi_total_retrans": (100, 4), "tcpi_pacing_rate": (104, 8),
    "tcpi_max_pacing_rate": (112, 8), "tcpi_bytes_acked": (120, 8),
    "tcpi_segs_out": (136, 4), "tcpi_segs_in": (140, 4),
    "tcpi_notsent_bytes": (144, 4), "tcpi_min_rtt": (148, 4),
    "tcpi_data_segs_out": (156, 4), "tcpi_delivery_rate": (160, 8),
    "tcpi_busy_time": (168, 8), "tcpi_rwnd_limited": (176, 8),
    "tcpi_sndbuf_limited": (184, 8), "tcpi_bytes_sent": (200, 8),
    "tcpi_bytes_retrans": (208, 8), "tcpi_snd_wnd": (228, 4),
    "tcpi_rcv_wnd": (232, 4),
}


def decode_tcp_info(raw_hex: str, byteorder: str) -> dict[str, int | None]:
    if byteorder not in ("little", "big"):
        raise ValueError(f"unsupported guest byte order: {byteorder!r}")
    raw = bytes.fromhex(raw_hex)
    if len(raw) < 104:
        raise ValueError(f"TCP_INFO is too short: {len(raw)} bytes")
    return {
        key: int.from_bytes(raw[offset:offset + size], byteorder)
        if len(raw) >= offset + size else None
        for key, (offset, size) in TCP_INFO_FIELDS.items()
    }


# Linux UAPI struct tcp_bbr_info (TCP_CC_INFO for bbr): five u32 fields.
# bw is bytes per second split into lo/hi words; gains are scaled by 256.
def decode_tcp_cc_info(raw_hex: str | None, byteorder: str, algorithm: str) -> dict[str, float | int] | None:
    if raw_hex is None or algorithm != "bbr":
        return None
    raw = bytes.fromhex(raw_hex)
    if len(raw) < 20:
        return None
    words = [int.from_bytes(raw[i:i + 4], byteorder) for i in range(0, 20, 4)]
    return {
        "bw_bytes_per_second": words[0] | (words[1] << 32),
        "min_rtt_us": words[2],
        "pacing_gain": words[3] / 256,
        "cwnd_gain": words[4] / 256,
    }


def save_tcp_flow_evidence(
    bench: Benchmark, endpoint: Endpoint, label: str, payload: dict[str, object],
    streams: int, seconds: float,
) -> None:
    evidence = payload.get("tcp_flow")
    if not isinstance(evidence, dict):
        raise RuntimeError("guest source did not export the requested TCP flow evidence")
    evidence.update({"endpoint": asdict(endpoint), "label": label,
                     "throughput_mib_per_second": payload.get("mib_per_second")})
    problems = list(evidence.get("errors", []))
    flows = evidence.get("flows", [])
    if len(flows) != streams:
        problems.append(f"expected {streams} TCP flows, got {len(flows)}")
    for flow in flows:
        if bench.tcp_congestion != "default" and flow.get("congestion_control") != bench.tcp_congestion:
            problems.append(f"unexpected live congestion algorithm for stream {flow['stream_id']}")
        snapshots = flow["snapshots"]
        for row in snapshots:
            try:
                row["tcp_info"] = decode_tcp_info(row["tcp_info_hex"], evidence["byteorder"])
            except (KeyError, TypeError, ValueError) as error:
                row["decode_error"] = str(error)
                problems.append(f"TCP_INFO decode failed for stream {flow['stream_id']}: {error}")
            try:
                bbr = decode_tcp_cc_info(row.get("tcp_cc_info_hex"), evidence["byteorder"],
                                         str(flow.get("congestion_control")))
            except (TypeError, ValueError):
                bbr = None
            if bbr is not None:
                row["bbr"] = bbr
        # Very short warmups may finish before the first sampling interval.
        if seconds >= 2 * bench.tcp_info_interval_ms / 1000:
            if not any(row["phase"] == "sending" and "tcp_info" in row for row in snapshots):
                problems.append(f"no live send samples for stream {flow['stream_id']}")
    evidence["validation_errors"] = problems
    (bench.output / f"{label}-tcp-flow.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8",
    )
    if problems:
        raise RuntimeError(f"incomplete TCP flow evidence; see {label}-tcp-flow.json")


def save_tcp_congestion_evidence(
    bench: Benchmark, endpoint: Endpoint, label: str,
    payload: dict[str, object], streams: int,
) -> None:
    evidence = payload.get("tcp_congestion")
    if not isinstance(evidence, dict):
        raise RuntimeError("guest source did not export the requested TCP congestion selection")
    evidence.update({"endpoint": asdict(endpoint), "label": label,
                     "throughput_mib_per_second": payload.get("mib_per_second")})
    problems = []
    if evidence.get("requested") != bench.tcp_congestion:
        problems.append("requested congestion algorithm does not match benchmark settings")
    flows = evidence.get("flows", [])
    if not isinstance(flows, list) or not all(isinstance(flow, dict) for flow in flows):
        problems.append("invalid per-stream congestion selections")
    elif (len(flows) != streams
          or any(type(flow.get("stream_id")) is not int for flow in flows)
          or {flow.get("stream_id") for flow in flows} != set(range(streams))
          or any(flow.get("algorithm") != bench.tcp_congestion for flow in flows)):
        problems.append("every stream must confirm the requested congestion algorithm")
    evidence["validation_errors"] = problems
    (bench.output / f"{label}-tcp-congestion.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8",
    )
    if problems:
        raise RuntimeError(f"invalid TCP congestion selection; see {label}-tcp-congestion.json")


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
    try:
        result = bench.run(
            label,
            [
                "container", "exec", endpoint.container_id,
                "python3", "-c", GUEST_SOURCE,
                host, str(port), str(streams), str(seconds), str(chunk_bytes),
                *([str(bench.tcp_info_interval_ms)]
                  if bench.tcp_info_interval_ms or bench.tcp_congestion != "default" else []),
                *([bench.tcp_congestion] if bench.tcp_congestion != "default" else []),
            ],
            timeout=max(bench.timeout, int(seconds) + 60),
        )
        payload = parse_json_line(result.stdout)
        if bench.tcp_congestion != "default":
            save_tcp_congestion_evidence(bench, endpoint, label, payload, streams)
        if bench.tcp_info_interval_ms:
            save_tcp_flow_evidence(bench, endpoint, label, payload, streams, seconds)
        return payload
    except Exception:
        bench.log(f"capturing network evidence for {label}; the transfer will not be retried")
        try:
            capture_guest_network_failure(bench, endpoint, host, port, label)
        except Exception as error:
            bench.log(f"network evidence capture failed: {error}")
        raise


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
            evidence_path = (
                bench.output / f"{label}-host-sink.json" if bench.tcp_info_interval_ms else None
            )
            with SinkServer(endpoint.gateway, evidence_path=evidence_path) as sink:
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
    parser.add_argument("--runtime-a-cpus", type=int)
    parser.add_argument("--runtime-b-cpus", type=int)
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
    parser.add_argument("--direction", choices=("both", "guest_to_host", "host_to_guest"), default="both")
    parser.add_argument("--tcp-info-interval-ms", type=int, default=0,
                        help="Read guest TCP state every N ms (0 disables; minimum 100)")
    parser.add_argument("--tcp-congestion", choices=("default", "bbr", "cubic", "reno"), default="default",
                        help="Guest sender socket congestion control; default keeps the kernel choice")
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--warmup-seconds", type=float, default=1.0)
    parser.add_argument("--guest-cap-add", action="append", default=[],
                        help="Linux capability granted to each endpoint (repeatable), e.g. CAP_NET_ADMIN")
    parser.add_argument("--guest-setup", default=None,
                        help="shell command run in each endpoint after it is ready, e.g. an RPS sysfs write")
    parser.add_argument("--iterations", type=int, default=4)
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    if args.seconds <= 0 or args.warmup_seconds <= 0 or args.iterations <= 0 or args.chunk_kib <= 0:
        parser.error("seconds, warmup-seconds, iterations, and chunk-kib must be positive")
    if args.tcp_info_interval_ms != 0 and args.tcp_info_interval_ms < 100:
        parser.error("tcp-info-interval-ms must be zero or at least 100")
    if args.tcp_info_interval_ms and args.direction == "host_to_guest":
        parser.error("TCP flow sampling requires the guest_to_host direction")
    if args.tcp_congestion != "default" and args.direction == "host_to_guest":
        parser.error("TCP congestion selection requires the guest_to_host direction")
    if args.runtime_a_cpus is not None and args.runtime_a_cpus <= 0:
        parser.error("runtime-a-cpus must be positive")
    if args.runtime_b_cpus is not None and args.runtime_b_cpus <= 0:
        parser.error("runtime-b-cpus must be positive")

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
    bench.tcp_info_interval_ms = args.tcp_info_interval_ms
    bench.tcp_congestion = args.tcp_congestion
    bench.guest_cap_add = list(args.guest_cap_add)
    bench.guest_setup = args.guest_setup
    endpoints: list[Endpoint] = []
    prefix = f"krun-streams-{token.lower()}"

    (output / "metadata.json").write_text(json.dumps({
        "runtime_a": args.runtime_a,
        "runtime_a_label": runtime_a_label,
        "runtime_a_backend": args.runtime_a_backend,
        "runtime_a_cpus": args.runtime_a_cpus,
        "runtime_b": args.runtime_b,
        "runtime_b_label": runtime_b_label,
        "runtime_b_backend": args.runtime_b_backend,
        "runtime_b_cpus": args.runtime_b_cpus,
        "control_marker": str(args.control_marker) if args.control_marker else None,
        "network": args.network,
        "image": args.image,
        "streams": args.streams,
        "direction": args.direction,
        "tcp_info_interval_ms": args.tcp_info_interval_ms,
        "tcp_congestion": args.tcp_congestion,
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
            (args.runtime_a, runtime_a_label, args.runtime_a_backend, args.runtime_a_cpus),
            (args.runtime_b, runtime_b_label, args.runtime_b_backend, args.runtime_b_cpus),
        )
        for slot, (runtime, label, backend, cpus) in enumerate(runtime_specs, start=1):
            configure_runtime_backend(args.control_marker, backend)
            endpoints.append(
                start_endpoint(bench, runtime, label, args.image, args.network, prefix, slot, cpus)
            )
        if args.control_marker is not None:
            args.control_marker.unlink(missing_ok=True)

        directions = ("guest_to_host", "host_to_guest") if args.direction == "both" else (args.direction,)
        for streams in args.streams:
            for direction in directions:
                run_direction(
                    bench, endpoints, direction, streams, args.seconds,
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
