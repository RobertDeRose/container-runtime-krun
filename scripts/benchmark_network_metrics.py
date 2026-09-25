#!/usr/bin/env python3
"""Collect paired network and RuntimeClient.dial benchmark samples."""

from __future__ import annotations

import argparse
import contextlib
import http.server
import ipaddress
import json
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


DIAL_PAYLOAD_BYTES = 64 * 1024 + 1


@dataclass(frozen=True)
class Endpoint:
    runtime: str
    container_id: str
    gateway: str
    tcp_port: int
    udp_port: int
    http_port: int


class Benchmark:
    def __init__(self, output: Path, samples: Path, timeout: int) -> None:
        self.output = output
        self.samples = samples
        self.timeout = timeout
        self.output.mkdir(parents=True, exist_ok=True)
        self.active_containers: set[str] = set()
        self.active_networks: set[str] = set()
        self.failed = False

    def log(self, message: str) -> None:
        print(f"[benchmark-network] {message}", flush=True)

    def run(
        self,
        label: str,
        argv: list[str],
        *,
        timeout: int | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        self.log(f"RUN {label}: {' '.join(argv)}")
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout or self.timeout,
            check=False,
        )
        path = self.output / f"{label}.txt"
        path.write_text(
            f"$ {' '.join(argv)}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
            encoding="utf-8",
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"{label} failed with exit {result.returncode}; see {path}")
        return result

    def append(self, runtime: str, metric: str, iteration: int, duration_ms: float, status: int) -> None:
        with self.samples.open("a", encoding="utf-8") as stream:
            stream.write(f"{runtime}\t{metric}\t{iteration}\t{duration_ms:.3f}\t{status}\n")

    def timed_command(self, runtime: str, metric: str, iteration: int, label: str, argv: list[str]) -> bool:
        start = time.perf_counter_ns()
        try:
            result = self.run(label, argv, check=False)
            status = result.returncode
        except Exception as error:
            duration_ms = elapsed_ms(start)
            self.append(runtime, metric, iteration, duration_ms, 1)
            self.failed = True
            self.log(f"{runtime}: {metric} sample {iteration} failed: {error}")
            return False
        duration_ms = elapsed_ms(start)
        self.append(runtime, metric, iteration, duration_ms, status)
        if status != 0:
            self.failed = True
            self.log(f"{runtime}: {metric} sample {iteration} failed with status {status}")
            return False
        return True

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
        for network in list(self.active_networks):
            subprocess.run(
                ["container", "network", "delete", network],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
                check=False,
            )
            self.active_networks.discard(network)


def elapsed_ms(start_ns: int) -> float:
    return (time.perf_counter_ns() - start_ns) / 1_000_000.0


def free_port(sock_type: int) -> int:
    with socket.socket(socket.AF_INET, sock_type) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def inspect_attachments(bench: Benchmark, container_id: str) -> list[dict[str, object]]:
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
                if isinstance(data, list) and len(data) == 1:
                    networks = data[0].get("status", {}).get("networks", [])
                    if isinstance(networks, list) and networks:
                        return networks
            except (json.JSONDecodeError, AttributeError):
                pass
        time.sleep(0.2)
    (bench.output / f"{container_id}-inspect-error.txt").write_text(last, encoding="utf-8")
    raise RuntimeError(f"{container_id}: network attachments did not become available")


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
    raise RuntimeError(f"{container_id}: benchmark guest services did not become ready")


def benchmark_lifecycle(
    bench: Benchmark,
    runtimes: list[str],
    image: str,
    network: str,
    multi_networks: tuple[str, str],
    iterations: int,
    prefix: str,
) -> None:
    for iteration in range(1, iterations + 1):
        order = runtimes if iteration % 2 else list(reversed(runtimes))
        for runtime in order:
            key = "".join(ch if ch.isalnum() else "-" for ch in runtime)
            container_id = f"{prefix}-{key}-network-{iteration}"
            bench.active_containers.add(container_id)
            started = bench.timed_command(
                runtime,
                "network_startup",
                iteration,
                f"{key}-network-start-{iteration}",
                [
                    "container", "run", "-d", "--name", container_id,
                    "--runtime", runtime, "--network", network, image,
                    "sh", "-c", 'trap "exit 0" TERM; while :; do sleep 1; done',
                ],
            )
            if started:
                bench.timed_command(
                    runtime,
                    "network_stop",
                    iteration,
                    f"{key}-network-stop-{iteration}",
                    ["container", "stop", container_id],
                )
                bench.timed_command(
                    runtime,
                    "network_delete",
                    iteration,
                    f"{key}-network-delete-{iteration}",
                    ["container", "delete", container_id],
                )
            else:
                subprocess.run(["container", "delete", "--force", container_id], capture_output=True, timeout=30)
            bench.active_containers.discard(container_id)

        for runtime in order:
            key = "".join(ch if ch.isalnum() else "-" for ch in runtime)
            container_id = f"{prefix}-{key}-multinic-{iteration}"
            bench.active_containers.add(container_id)
            started = bench.timed_command(
                runtime,
                "multinic_startup",
                iteration,
                f"{key}-multinic-start-{iteration}",
                [
                    "container", "run", "-d", "--name", container_id,
                    "--runtime", runtime,
                    "--network", multi_networks[0], "--network", multi_networks[1],
                    image, "sh", "-c", 'trap "exit 0" TERM; while :; do sleep 1; done',
                ],
            )
            if started:
                attachments = inspect_attachments(bench, container_id)
                if len(attachments) != 2:
                    bench.failed = True
                    bench.log(f"{runtime}: multinic_startup returned {len(attachments)} attachments")
                bench.timed_command(
                    runtime,
                    "multinic_stop",
                    iteration,
                    f"{key}-multinic-stop-{iteration}",
                    ["container", "stop", container_id],
                )
                bench.timed_command(
                    runtime,
                    "multinic_delete",
                    iteration,
                    f"{key}-multinic-delete-{iteration}",
                    ["container", "delete", container_id],
                )
            else:
                subprocess.run(["container", "delete", "--force", container_id], capture_output=True, timeout=30)
            bench.active_containers.discard(container_id)


GUEST_SERVER = r'''
import http.server
import socket
import sys
import threading
import time

payload_bytes = int(sys.argv[1])
vsock_port = int(sys.argv[2])
vsock_payload_bytes = int(sys.argv[3])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/upload":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length != payload_bytes:
            self.send_error(400)
            return
        remaining = length
        while remaining:
            chunk = self.rfile.read(min(1024 * 1024, remaining))
            if not chunk:
                self.send_error(400)
                return
            remaining -= len(chunk)
        self.send_response(204)
        self.end_headers()
    def log_message(self, fmt, *args):
        pass

def tcp_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 8080))
    server.listen(16)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=echo_stream, args=(conn, None), daemon=True).start()

def echo_stream(conn, expected):
    with conn:
        data = bytearray()
        while expected is None or len(data) < expected:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data.extend(chunk)
            if expected is None:
                break
        conn.sendall(data)

def udp_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("0.0.0.0", 8081))
    while True:
        data, addr = server.recvfrom(65535)
        server.sendto(data, addr)

def vsock_server():
    if not hasattr(socket, "AF_VSOCK"):
        raise RuntimeError("Python does not expose AF_VSOCK")
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((socket.VMADDR_CID_ANY, vsock_port))
    server.listen(16)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=echo_stream, args=(conn, vsock_payload_bytes), daemon=True).start()

httpd = http.server.ThreadingHTTPServer(("0.0.0.0", 8082), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
threading.Thread(target=tcp_server, daemon=True).start()
threading.Thread(target=udp_server, daemon=True).start()
threading.Thread(target=vsock_server, daemon=True).start()
print("READY", flush=True)
while True:
    time.sleep(3600)
'''


def start_endpoint(
    bench: Benchmark,
    runtime: str,
    image: str,
    network: str,
    payload_bytes: int,
    dial_port: int,
    prefix: str,
) -> Endpoint:
    key = "".join(ch if ch.isalnum() else "-" for ch in runtime)
    container_id = f"{prefix}-{key}-network-live"
    tcp_port = free_port(socket.SOCK_STREAM)
    udp_port = free_port(socket.SOCK_DGRAM)
    http_port = free_port(socket.SOCK_STREAM)
    bench.active_containers.add(container_id)
    bench.run(
        f"{key}-network-service-start",
        [
            "container", "run", "-d", "--name", container_id,
            "--runtime", runtime, "--network", network,
            "--publish", f"127.0.0.1:{tcp_port}:8080/tcp",
            "--publish", f"127.0.0.1:{udp_port}:8081/udp",
            "--publish", f"127.0.0.1:{http_port}:8082/tcp",
            image, "python3", "-u", "-c", GUEST_SERVER,
            str(payload_bytes), str(dial_port), str(DIAL_PAYLOAD_BYTES),
        ],
    )
    wait_ready(bench, container_id)
    attachments = inspect_attachments(bench, container_id)
    first = attachments[0]
    gateway = str(ipaddress.IPv4Address(str(first["ipv4Gateway"])))
    return Endpoint(runtime, container_id, gateway, tcp_port, udp_port, http_port)


def http_upload(host: str, port: int, payload: bytes) -> float:
    import http.client

    connection = http.client.HTTPConnection(host, port, timeout=30)
    start = time.perf_counter_ns()
    try:
        connection.request(
            "POST",
            "/upload",
            body=payload,
            headers={"Content-Length": str(len(payload))},
        )
        response = connection.getresponse()
        response.read()
        duration = elapsed_ms(start)
    finally:
        connection.close()
    if response.status != 204:
        raise RuntimeError(f"expected HTTP 204, got {response.status}")
    return duration


@contextlib.contextmanager
def host_sink_server(address: str, expected_bytes: int) -> Iterator[int]:
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            if self.path != "/upload":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length != expected_bytes:
                self.send_error(400)
                return
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    self.send_error(400)
                    return
                remaining -= len(chunk)
            self.send_response(204)
            self.end_headers()

        def log_message(self, fmt: str, *args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer((address, 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    thread.start()
    try:
        yield int(server.server_port)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def guest_http_upload(bench: Benchmark, endpoint: Endpoint, host_port: int, payload_bytes: int, label: str) -> float:
    script = r'''
import http.client
import sys
import time
host = sys.argv[1]
port = int(sys.argv[2])
payload_bytes = int(sys.argv[3])
payload = b"g" * payload_bytes
connection = http.client.HTTPConnection(host, port, timeout=30)
start = time.perf_counter_ns()
try:
    connection.request(
        "POST",
        "/upload",
        body=payload,
        headers={"Content-Length": str(payload_bytes)},
    )
    response = connection.getresponse()
    response.read()
finally:
    connection.close()
if response.status != 204:
    raise SystemExit(f"expected HTTP 204, got {response.status}")
print(f"{(time.perf_counter_ns() - start) / 1_000_000:.6f}")
'''
    result = bench.run(
        label,
        [
            "container", "exec", endpoint.container_id,
            "python3", "-c", script,
            endpoint.gateway, str(host_port), str(payload_bytes),
        ],
    )
    return float(result.stdout.strip().splitlines()[-1])


def recv_exact(sock: socket.socket, length: int) -> bytes:
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def published_tcp(endpoint: Endpoint) -> float:
    payload = b"published-tcp-benchmark\n"
    start = time.perf_counter_ns()
    with socket.create_connection(("127.0.0.1", endpoint.tcp_port), timeout=10) as sock:
        sock.settimeout(10)
        sock.sendall(payload)
        response = recv_exact(sock, len(payload))
    duration = elapsed_ms(start)
    if response != payload:
        raise RuntimeError(f"published TCP echo mismatch for {endpoint.runtime}: {response!r}")
    return duration


def published_udp(endpoint: Endpoint) -> float:
    payload = b"published-udp-benchmark"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(10)
        start = time.perf_counter_ns()
        sock.sendto(payload, ("127.0.0.1", endpoint.udp_port))
        response, _ = sock.recvfrom(65535)
        duration = elapsed_ms(start)
    if response != payload:
        raise RuntimeError(f"published UDP echo mismatch for {endpoint.runtime}: {response!r}")
    return duration


def sample_metric(
    bench: Benchmark,
    endpoints: list[Endpoint],
    iterations: int,
    metric: str,
    fn,
) -> None:
    for iteration in range(1, iterations + 1):
        order = endpoints if iteration % 2 else list(reversed(endpoints))
        for endpoint in order:
            start = time.perf_counter_ns()
            try:
                duration_ms = float(fn(endpoint, iteration))
                status = 0
            except Exception as error:
                duration_ms = elapsed_ms(start)
                status = 1
                bench.failed = True
                bench.log(f"{endpoint.runtime}: {metric} sample {iteration} failed: {error}")
            bench.append(endpoint.runtime, metric, iteration, duration_ms, status)


def run_dial_probe(bench: Benchmark, endpoints: list[Endpoint], iterations: int, dial_port: int) -> None:
    if len(endpoints) != 2:
        raise ValueError("RuntimeClient.dial benchmark requires exactly two runtime endpoints")
    endpoint_a, endpoint_b = endpoints
    environment = dict(**__import__("os").environ)
    environment.update(
        {
            "KRUN_RUNTIME_DIAL_BENCHMARK_CONTAINER_ID_A": endpoint_a.container_id,
            "KRUN_RUNTIME_DIAL_BENCHMARK_RUNTIME_A": endpoint_a.runtime,
            "KRUN_RUNTIME_DIAL_BENCHMARK_CONTAINER_ID_B": endpoint_b.container_id,
            "KRUN_RUNTIME_DIAL_BENCHMARK_RUNTIME_B": endpoint_b.runtime,
            "KRUN_RUNTIME_DIAL_BENCHMARK_PORT": str(dial_port),
            "KRUN_RUNTIME_DIAL_BENCHMARK_ITERATIONS": str(iterations),
            "KRUN_RUNTIME_DIAL_BENCHMARK_SAMPLES": str(bench.samples.resolve()),
        }
    )
    bench.log("RUN paired-dial-probe")
    result = subprocess.run(
        ["swift", "test", "--force-resolved-versions", "--filter", "runtimeDialBenchmarkProbe"],
        capture_output=True,
        text=True,
        timeout=max(bench.timeout, iterations * 60),
        check=False,
        env=environment,
    )
    (bench.output / "paired-dial-probe.txt").write_text(
        f"$ swift test --force-resolved-versions --filter runtimeDialBenchmarkProbe\n"
        f"{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
        encoding="utf-8",
    )
    if result.returncode != 0:
        bench.failed = True
        bench.log("paired RuntimeClient.dial benchmark probe failed")


def wait_port_bindable(sock_type: int, port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, sock_type) as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                time.sleep(0.1)
                continue
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--runtime-a", required=True)
    parser.add_argument("--runtime-b", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--network-image", required=True)
    parser.add_argument("--payload-mib", type=int, required=True)
    parser.add_argument("--iterations", type=int, required=True)
    parser.add_argument("--subnet-a", required=True)
    parser.add_argument("--subnet-b", required=True)
    parser.add_argument("--dial-port", type=int, required=True)
    parser.add_argument("--timeout", type=int, required=True)
    args = parser.parse_args()

    if args.iterations <= 0 or args.payload_mib <= 0:
        parser.error("iterations and payload-mib must be positive")

    bench = Benchmark(args.output, args.samples, args.timeout)
    runtimes = [args.runtime_a, args.runtime_b]
    network_prefix = args.prefix.lower()
    net_a = f"{network_prefix}-net-a"
    net_b = f"{network_prefix}-net-b"
    payload_bytes = args.payload_mib * 1024 * 1024
    endpoints: list[Endpoint] = []

    try:
        bench.run("network-create-a", [
            "container", "network", "create", "--subnet", args.subnet_a,
            "--option", "variant=allocationOnly", net_a,
        ])
        bench.active_networks.add(net_a)
        bench.run("network-create-b", [
            "container", "network", "create", "--subnet", args.subnet_b,
            "--option", "variant=allocationOnly", net_b,
        ])
        bench.active_networks.add(net_b)

        benchmark_lifecycle(
            bench, runtimes, args.image, args.network, (net_a, net_b), args.iterations, args.prefix
        )

        for runtime in runtimes:
            endpoint = start_endpoint(
                bench, runtime, args.network_image, args.network, payload_bytes, args.dial_port, args.prefix
            )
            endpoints.append(endpoint)

        host_payload = b"h" * payload_bytes
        sample_metric(
            bench,
            endpoints,
            args.iterations,
            f"published_tcp_host_to_guest_{args.payload_mib}m",
            lambda endpoint, _: http_upload("127.0.0.1", endpoint.http_port, host_payload),
        )

        def guest_to_host(endpoint: Endpoint, iteration: int) -> float:
            with host_sink_server(endpoint.gateway, payload_bytes) as host_port:
                key = "".join(ch if ch.isalnum() else "-" for ch in endpoint.runtime)
                return guest_http_upload(
                    bench,
                    endpoint,
                    host_port,
                    payload_bytes,
                    f"{key}-guest-to-host-{iteration}",
                )

        sample_metric(
            bench,
            endpoints,
            args.iterations,
            f"network_guest_to_host_{args.payload_mib}m",
            guest_to_host,
        )
        sample_metric(
            bench,
            endpoints,
            args.iterations,
            "published_tcp_rtt",
            lambda endpoint, _: published_tcp(endpoint),
        )
        sample_metric(
            bench,
            endpoints,
            args.iterations,
            "published_udp_rtt",
            lambda endpoint, _: published_udp(endpoint),
        )

        run_dial_probe(bench, endpoints, args.iterations, args.dial_port)

        for endpoint in endpoints:
            key = "".join(ch if ch.isalnum() else "-" for ch in endpoint.runtime)
            bench.run(f"{key}-network-service-stop", ["container", "stop", endpoint.container_id])
            bench.run(f"{key}-network-service-delete", ["container", "delete", endpoint.container_id])
            bench.active_containers.discard(endpoint.container_id)
            if not wait_port_bindable(socket.SOCK_STREAM, endpoint.tcp_port):
                bench.failed = True
                bench.log(f"{endpoint.runtime}: published TCP port was not released")
            if not wait_port_bindable(socket.SOCK_DGRAM, endpoint.udp_port):
                bench.failed = True
                bench.log(f"{endpoint.runtime}: published UDP port was not released")

    except Exception as error:
        bench.failed = True
        bench.log(f"fatal benchmark setup error: {error}")
    finally:
        bench.cleanup()

    return 1 if bench.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
