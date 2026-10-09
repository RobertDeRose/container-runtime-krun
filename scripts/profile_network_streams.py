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
from contextlib import contextmanager, nullcontext
from datetime import datetime, timezone
from pathlib import Path

import benchmark_network_streams as streams_bench
import native_vmnet_validation as native_validation
import profile_network_guest_cpu as guest_profile
from network_host_activity import HostActivity, ThreadReader


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


def start_top(pid: int, seconds: int, output: Path, *, whole_host: bool = False) -> subprocess.Popen[str]:
    argv = [
        "/usr/bin/top",
        "-l",
        str(max(1, seconds)),
        "-s",
        "1",
        *(["-o", "cpu", "-n", "20"] if whole_host else ["-pid", str(pid)]),
        "-stats",
        "pid,command,cpu,threads,mem,time",
    ]
    stream = (output / ("host-top.txt" if whole_host else "vmm-top.txt")).open("w", encoding="utf-8")
    try:
        proc = subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT, text=True)
    except BaseException:
        stream.close()
        raise
    proc._profile_stream = stream  # type: ignore[attr-defined]
    return proc


def finish_top(proc: subprocess.Popen[str], timeout: int) -> int:
    try:
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            return 124
    finally:
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
        with streams_bench.SinkServer(
            endpoint.gateway, evidence_path=bench.output / "profile-host-sink.json"
        ) as sink:
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


def capture_installed_provenance(output: Path, stage: str) -> dict[str, object]:
    """Verify installed files, independently of the local checkout HEAD."""
    manifest = (native_validation.TRUSTED / "lib/libkrun.provenance").read_text()
    (output / f"installed-{stage}.provenance").write_text(manifest, encoding="utf-8")
    values = native_validation.provenance(manifest)
    binary = shutil.which("container")
    if not binary:
        raise RuntimeError("container CLI is unavailable")
    cli = Path(binary).resolve()
    install_root = os.environ.get("INSTALL_ROOT")
    if not install_root:
        if cli.parent.name != "bin":
            raise RuntimeError("cannot derive installed runtime path; set INSTALL_ROOT")
        install_root = str(cli.parent.parent)
    plugin = Path(install_root) / "libexec/container-plugins/container-runtime-krun"
    version = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=10, check=True)
    evidence: dict[str, object] = {
        "commit": values["commit"], "provenance": values, "files": [], "verified": False,
        "container_cli": {"path": str(cli), "sha256": native_validation.digest(cli),
                          "version": version.stdout.strip()},
    }
    try:
        for path, key in (
            (native_validation.LIBRARY, "sha256"),
            (native_validation.HELPER, "helper_sha256"),
            (plugin / "bin/container-runtime-krun", "runtime_sha256"),
        ):
            if not path.is_file():
                raise RuntimeError(f"installed native image not found: {path}; select the matching container CLI/install root")
            actual = native_validation.digest(path)
            evidence["files"].append({"path": str(path), "sha256": actual, "recorded_sha256": values[key]})
            if actual != values[key]:
                raise RuntimeError(f"installed hash does not match provenance: {path}")
        evidence["verified"] = True
        return evidence
    finally:
        (output / f"installed-{stage}.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


@contextmanager
def tx_attribution(output: Path, helper_pid: int, seconds: int):
    """Correlate existing opt-in TX counters with external thread CPU readings."""
    reader = ThreadReader()
    if reader.executable(helper_pid) != str(native_validation.HELPER):
        raise RuntimeError("TX attribution requires the protected native VMM helper")
    helper = guest_profile.krun_helper_processes().get(helper_pid)
    if helper is None:
        raise RuntimeError(f"cannot find profiling log for VMM PID {helper_pid}")
    shutil.copyfile(helper.config_path, output / "krun-vmm.json")
    activity = HostActivity(output / "host-activity.json",
                            {"vmm": helper_pid, "harness_and_sink": os.getpid()}, seconds, reader)
    evidence: dict[str, object] = {"clock": "host monotonic nanoseconds"}
    reset = False
    primary_error = None
    errors = []
    try:
        activity.start()
        evidence["reset_requested_ns"] = time.monotonic_ns()
        guest_profile.reset_tx_datapath(helper)
        reset = True
        evidence["reset_ack_ns"] = time.monotonic_ns()
        yield
    except BaseException as error:
        primary_error = error
        raise
    finally:
        if reset:
            try:
                evidence["snapshot_requested_ns"] = time.monotonic_ns()
                evidence["counters"] = guest_profile.snapshot_tx_datapath(helper)
                evidence["snapshot_ack_ns"] = time.monotonic_ns()
            except Exception as error:
                errors.append(f"TX snapshot: {error!r}")
        for label, action in (
            ("host activity", activity.finish),
            ("VMM log", lambda: shutil.copyfile(helper.log_path, output / "krun-vmm.log")),
        ):
            try:
                action()
            except Exception as error:
                errors.append(f"{label}: {error!r}")
        evidence["errors"] = errors
        evidence["primary_error"] = repr(primary_error) if primary_error else None
        try:
            (output / "tx-attribution.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        except OSError as error:
            errors.append(f"TX evidence write: {error!r}")
        if errors:
            if primary_error is None:
                raise RuntimeError("incomplete TX attribution: " + "; ".join(errors))
            print("[network-profile] additional attribution failures: " + "; ".join(errors), file=sys.stderr)


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
    parser.add_argument("--tx-attribution", action="store_true",
                        help="Native krun only: verify installed files, capture TX counters and host thread CPU")
    parser.add_argument("--chunk-kib", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()

    if platform.system() != "Darwin":
        parser.error("profile:network-streams requires macOS")
    if args.tx_attribution and args.runtime != "container-runtime-krun":
        parser.error("TX attribution requires container-runtime-krun; Apple host profiling is not supported")
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
    installed = None
    source_thread = None
    source_deadline = 0.0
    error_holder: list[str] = []

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
        "tx_attribution": args.tx_attribution,
        "host_sink_pid": os.getpid(),
    }

    try:
        if args.tx_attribution:
            installed = capture_installed_provenance(output, "before")
            metadata["installed_libkrun_commit"] = installed["commit"]
        endpoint = streams_bench.start_endpoint(
            bench, args.runtime, args.runtime, args.image, args.network, prefix, slot=1
        )
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
        source_deadline = time.monotonic() + args.seconds + args.timeout
        source_thread.start()
        time.sleep(args.sample_delay)

        (output / "ps-profile-start.txt").write_text(process_listing(), encoding="utf-8")
        attribution = tx_attribution(output, helper_pid, args.sample_seconds) if args.tx_attribution else nullcontext()
        with attribution:
            top_proc = start_top(helper_pid, args.sample_seconds, output, whole_host=args.tx_attribution)
            sample_failed = True
            try:
                run_sample(helper_pid, args.sample_seconds, args.sample_interval_ms, output)
                capture_command(output, "vmm-threads-during.txt", thread_snapshot_argv(helper_pid))
                sample_failed = False
            finally:
                try:
                    top_status = finish_top(top_proc, args.sample_seconds + 10)
                    (output / "top-status.txt").write_text(f"exit_status={top_status}\n", encoding="utf-8")
                    if args.tx_attribution and top_status != 0:
                        raise RuntimeError(f"host top capture failed with exit {top_status}")
                except Exception as error:
                    if not sample_failed:
                        raise
                    print(f"[network-profile] additional top failure: {error!r}", file=sys.stderr)

        (output / "ps-profile-end.txt").write_text(process_listing(), encoding="utf-8")
        source_thread.join(timeout=max(0, source_deadline - time.monotonic()))
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
        # A profiler/collector failure must not archive while the source and its
        # sink are still writing evidence. Keep the existing bounded source wait.
        if source_thread is not None and source_thread.ident is not None:
            source_thread.join(timeout=max(0, source_deadline - time.monotonic()))
            if source_thread.is_alive():
                failed = True
                error_holder.append("profile source did not terminate before cleanup")
        if error_holder:
            failed = True
            (output / "source-errors.json").write_text(json.dumps(error_holder, indent=2) + "\n", encoding="utf-8")
        if installed is not None:
            try:
                if capture_installed_provenance(output, "after") != installed:
                    raise RuntimeError("installed files/provenance changed during profiling")
            except Exception as error:
                failed = True
                (output / "installation-error.txt").write_text(repr(error) + "\n", encoding="utf-8")
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
