#!/usr/bin/env python3
"""Externally profile sustained krun guest-to-host TCP throughput on macOS."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import benchmark_network_streams as streams_bench


HELPER_NAME = "container-krun-vmm-helper"
SUDO_PATH = "/usr/bin/sudo"


def process_listing() -> str:
    result = subprocess.run(
        [
            "/bin/ps",
            "-axo",
            "pid=,ppid=,uid=,%cpu=,%mem=,rss=,vsz=,state=,etime=,command=",
        ],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    return result.stdout + result.stderr


def helper_pids(listing: str) -> dict[int, str]:
    found: dict[int, str] = {}
    for line in listing.splitlines():
        fields = line.strip().split(None, 9)
        if len(fields) < 10:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue

        # The runtime launches the VMM through ``sudo -n -- helper ...``.  The
        # sudo wrapper's command line therefore contains HELPER_NAME as well,
        # but sampling it would profile sudo rather than the VMM.  Only accept
        # rows whose actual executable is the helper itself.
        command = fields[9]
        executable = command.split(None, 1)[0]
        if Path(executable).name != HELPER_NAME:
            continue

        found[pid] = line
    return found


def find_new_helper(before: set[int], listing: str, container_id: str) -> int:
    after = helper_pids(listing)
    new_pids = sorted(set(after) - before)
    if len(new_pids) == 1:
        return new_pids[0]

    matching = sorted(pid for pid, line in after.items() if container_id in line)
    if len(matching) == 1:
        return matching[0]

    raise RuntimeError(
        "unable to identify a unique container-krun-vmm-helper process; "
        f"new={new_pids} matching_container={matching} all={sorted(after)}"
    )


def privileged_argv(argv: list[str]) -> list[str]:
    return [SUDO_PATH, "-n", "--", *argv]


def authorize_profiler() -> None:
    result = subprocess.run([SUDO_PATH, "-v"], check=False)
    if result.returncode != 0:
        raise RuntimeError("sudo authorization is required to profile the VMM helper")


def thread_snapshot_argv(pid: int) -> list[str]:
    return [
        "/bin/ps",
        "-M",
        "-p",
        str(pid),
        "-o",
        "pid=,%cpu=,state=,time=,command=",
    ]


def capture_command(output: Path, name: str, argv: list[str], timeout: int = 30) -> int:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        body = f"$ {' '.join(argv)}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n"
        status = result.returncode
    except FileNotFoundError as error:
        body = f"$ {' '.join(argv)}\n{error!r}\nexit_status=127\n"
        status = 127
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        body = f"$ {' '.join(argv)}\n{stdout}{stderr}\ntimeout={timeout}\nexit_status=124\n"
        status = 124
    (output / name).write_text(body, encoding="utf-8")
    return status


def sample_argv(pid: int, seconds: int, interval_ms: int, sample_path: Path) -> list[str]:
    return privileged_argv(
        [
            "/usr/bin/sample",
            str(pid),
            str(seconds),
            str(interval_ms),
            "-file",
            str(sample_path),
        ]
    )


def run_sample(pid: int, seconds: int, interval_ms: int, output: Path) -> None:
    sample_path = output / "vmm-sample.txt"
    status_path = output / "vmm-sample-status.txt"
    argv = sample_argv(pid, seconds, interval_ms, sample_path)
    result = subprocess.run(argv, capture_output=True, text=True, timeout=seconds + 30, check=False)
    status_path.write_text(
        f"$ {' '.join(argv)}\n{result.stdout}{result.stderr}\nexit_status={result.returncode}\n",
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise RuntimeError(f"sample failed with exit {result.returncode}")


def start_top(pid: int, seconds: int, output: Path) -> subprocess.Popen[str]:
    argv = [
        "/usr/bin/top",
        "-l",
        str(max(1, seconds)),
        "-s",
        "1",
        "-pid",
        str(pid),
        "-stats",
        "pid,command,cpu,threads,mem,time",
    ]
    stream = (output / "vmm-top.txt").open("w", encoding="utf-8")
    proc = subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, text=True)
    proc._profile_stream = stream  # type: ignore[attr-defined]
    return proc


def finish_top(proc: subprocess.Popen[str], timeout: int) -> None:
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    stream = getattr(proc, "_profile_stream", None)
    if stream is not None:
        stream.close()


def run_profile_source(
    bench: streams_bench.Benchmark,
    endpoint: streams_bench.Endpoint,
    streams: int,
    seconds: float,
    chunk_bytes: int,
    result_holder: dict[str, object],
    error_holder: list[str],
) -> None:
    try:
        with streams_bench.SinkServer(endpoint.gateway) as sink:
            result_holder.update(
                streams_bench.guest_source(
                    bench,
                    endpoint,
                    endpoint.gateway,
                    sink.port,
                    streams,
                    seconds,
                    chunk_bytes,
                    "profile-guest-to-host-source",
                )
            )
    except Exception as error:
        error_holder.append(repr(error))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default="container-runtime-krun")
    parser.add_argument("--network", default="default")
    parser.add_argument("--image", default="python:3.13-alpine")
    parser.add_argument("--streams", type=int, default=8)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--warmup-seconds", type=float, default=3.0)
    parser.add_argument("--sample-delay", type=float, default=2.0)
    parser.add_argument("--sample-seconds", type=int, default=20)
    parser.add_argument("--sample-interval-ms", type=int, default=10)
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    if platform.system() != "Darwin":
        parser.error("profile:network-streams requires macOS")
    if args.streams <= 0 or args.seconds <= 0 or args.warmup_seconds <= 0 or args.chunk_kib <= 0:
        parser.error("streams, seconds, warmup-seconds, and chunk-kib must be positive")
    if args.sample_delay < 0 or args.sample_seconds <= 0 or args.sample_interval_ms <= 0:
        parser.error(
            "sample-delay must be non-negative and sample-seconds/sample-interval-ms must be positive"
        )
    if args.sample_delay + args.sample_seconds >= args.seconds:
        parser.error("sample-delay + sample-seconds must be less than the source duration")
    if not Path("/usr/bin/sample").is_file():
        parser.error("/usr/bin/sample is unavailable")
    if not Path(SUDO_PATH).is_file():
        parser.error(f"{SUDO_PATH} is unavailable")

    authorize_profiler()

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"network-profile-{token}"
    archive = args.result_root / f"container-runtime-krun-network-profile-{token}.tar.gz"
    args.result_root.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    bench = streams_bench.Benchmark(output, args.timeout)
    prefix = f"krun-profile-{token.lower()}"
    endpoint: streams_bench.Endpoint | None = None
    failed = False

    initial_listing = process_listing()
    (output / "ps-before-endpoint.txt").write_text(initial_listing, encoding="utf-8")
    before_helpers = set(helper_pids(initial_listing))

    metadata = {
        "runtime": args.runtime,
        "network": args.network,
        "image": args.image,
        "direction": "guest_to_host",
        "streams": args.streams,
        "seconds": args.seconds,
        "warmup_seconds": args.warmup_seconds,
        "sample_delay": args.sample_delay,
        "sample_seconds": args.sample_seconds,
        "sample_interval_ms": args.sample_interval_ms,
        "chunk_kib": args.chunk_kib,
        "repository_head": streams_bench.git_head(Path.cwd()),
        "libkrun_head": streams_bench.git_head(Path(".build-deps/libkrun")),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "sample_path": shutil.which("sample") or "/usr/bin/sample",
    }

    try:
        endpoint = streams_bench.start_endpoint(bench, args.runtime, args.image, args.network, prefix)
        endpoint_listing = process_listing()
        (output / "ps-after-endpoint.txt").write_text(endpoint_listing, encoding="utf-8")
        helper_pid = find_new_helper(before_helpers, endpoint_listing, endpoint.container_id)
        metadata["helper_pid"] = helper_pid
        metadata["container_id"] = endpoint.container_id
        (output / "helper-pid.txt").write_text(f"{helper_pid}\n", encoding="utf-8")

        bench.log(f"warmup {args.runtime} guest_to_host P{args.streams}")
        with streams_bench.SinkServer(endpoint.gateway) as sink:
            warmup = streams_bench.guest_source(
                bench,
                endpoint,
                endpoint.gateway,
                sink.port,
                args.streams,
                args.warmup_seconds,
                args.chunk_kib * 1024,
                "profile-warmup",
            )
        (output / "warmup-result.json").write_text(json.dumps(warmup, indent=2) + "\n", encoding="utf-8")

        capture_command(
            output,
            "vmm-vmmap-before.txt",
            privileged_argv(["/usr/bin/vmmap", "-summary", str(helper_pid)]),
        )
        capture_command(output, "vmm-threads-before.txt", thread_snapshot_argv(helper_pid))

        result_holder: dict[str, object] = {}
        error_holder: list[str] = []
        source_thread = threading.Thread(
            target=run_profile_source,
            args=(
                bench,
                endpoint,
                args.streams,
                args.seconds,
                args.chunk_kib * 1024,
                result_holder,
                error_holder,
            ),
            daemon=True,
        )
        source_thread.start()
        time.sleep(args.sample_delay)

        (output / "ps-profile-start.txt").write_text(process_listing(), encoding="utf-8")
        top_proc = start_top(helper_pid, args.sample_seconds, output)
        try:
            run_sample(helper_pid, args.sample_seconds, args.sample_interval_ms, output)
            capture_command(output, "vmm-threads-during.txt", thread_snapshot_argv(helper_pid))
        finally:
            finish_top(top_proc, args.sample_seconds + 10)

        (output / "ps-profile-end.txt").write_text(process_listing(), encoding="utf-8")
        source_thread.join(timeout=args.seconds + args.timeout)
        if source_thread.is_alive():
            raise RuntimeError("profile source did not terminate")
        if error_holder:
            raise RuntimeError("; ".join(error_holder))
        if not result_holder:
            raise RuntimeError("profile source produced no result")

        (output / "profile-result.json").write_text(
            json.dumps(result_holder, indent=2) + "\n", encoding="utf-8"
        )
        capture_command(
            output,
            "vmm-vmmap-after.txt",
            privileged_argv(["/usr/bin/vmmap", "-summary", str(helper_pid)]),
        )
        capture_command(output, "vmm-threads-after.txt", thread_snapshot_argv(helper_pid))
    except Exception as error:
        failed = True
        bench.log(f"profile failed: {error}")
        (output / "fatal-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
    finally:
        metadata["result"] = "FAIL" if failed else "PASS"
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        bench.cleanup()
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(output, arcname=output.name)

    print(f"result={'FAIL' if failed else 'PASS'}")
    print(f"output={output}")
    print(f"archive={archive}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
