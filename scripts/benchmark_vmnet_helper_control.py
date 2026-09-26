#!/usr/bin/env python3
"""Benchmark the repository libkrun through krunkit + vmnet-helper offloading."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import yaml

import benchmark_network_streams as streams_bench

MIB = 1024 * 1024
VMNET_HELPER_REPOSITORY = "https://github.com/nirs/vmnet-helper.git"
VMNET_HELPER_COMMIT = "101f10944bfa8e19ca8d99e79ade03f497f65d8a"
KRUNKIT_REPOSITORY = "https://github.com/libkrun/krunkit.git"
KRUNKIT_COMMIT = "d2b085f6eabebc194f9c688fef0166bdaecb9677"
LIBKRUN_DYLIB = "libkrun.1.19.4.dylib"
KRUNKIT_CONTROL_PATCH = "headless-no-gpu-v1"

KRUNKIT_GPU_BLOCK = """        // Temporarily enable GPU by default
        let virgl_flags = VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL;
        let sys = sysinfo::System::new_all();
        // Limit RAM + VRAM to 64 GB (36 bit IPA address limit) minus 2 GB (start address plus rounding).
        let rounded_mem = ((args.memory as u64) / 1024 + 1) * 1024;
        let vram = std::cmp::min((63488 - rounded_mem) * 1024 * 1024, sys.total_memory());
        if unsafe { krun_set_gpu_options2(id, virgl_flags, vram) } < 0 {
            return Err(anyhow!(\"unable to set krun vCPU/RAM configuration\"));
        }

"""

KRUNKIT_HEADLESS_BLOCK = """        // The control must use the runtime's BLK+NET libkrun build exactly as-is.
        // Do not configure krunkit's optional GPU path for this headless network benchmark.

"""


@dataclass(frozen=True)
class Sample:
    streams: int
    iteration: int
    bits_per_second: float
    mib_per_second: float


def parse_streams(value: str) -> list[int]:
    try:
        streams = [int(item.strip()) for item in value.split(",") if item.strip()]
    except ValueError as error:
        raise argparse.ArgumentTypeError("streams must be comma-separated positive integers") from error
    if not streams or any(item <= 0 for item in streams):
        raise argparse.ArgumentTypeError("streams must be comma-separated positive integers")
    return streams


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("cannot calculate percentile of empty values")
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def summarize(samples: list[Sample]) -> list[dict[str, float | int]]:
    rows: list[dict[str, float | int]] = []
    for streams in sorted({sample.streams for sample in samples}):
        rates = [sample.mib_per_second for sample in samples if sample.streams == streams]
        rows.append({
            "streams": streams,
            "samples": len(rates),
            "median_mib_per_second": statistics.median(rates),
            "p10_mib_per_second": percentile(rates, 0.10),
            "p90_mib_per_second": percentile(rates, 0.90),
            "min_mib_per_second": min(rates),
            "max_mib_per_second": max(rates),
        })
    return rows


def git_head(path: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    timeout: int = 300,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    print("[vmnet-helper-control] RUN " + " ".join(str(item) for item in argv), flush=True)
    result = subprocess.run(
        argv,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(argv)}\n{result.stdout}{result.stderr}"
        )
    return result


def ensure_checkout(path: Path, repository: str, commit: str, timeout: int) -> None:
    if not (path / ".git").is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--filter=blob:none", repository, str(path)], timeout=timeout)
    status = run(
        ["git", "-C", str(path), "status", "--porcelain=v1", "--untracked-files=all"],
        timeout=timeout,
    ).stdout.strip()
    if status:
        raise RuntimeError(f"control dependency checkout is dirty: {path}\n{status}")
    current = git_head(path)
    if current != commit:
        run(["git", "-C", str(path), "fetch", "origin", commit], timeout=timeout)
        run(["git", "-C", str(path), "checkout", "--detach", commit], timeout=timeout)



def patch_krunkit_headless(checkout: Path) -> tuple[Path, str]:
    context = checkout / "src/context.rs"
    source = context.read_text(encoding="utf-8")
    if KRUNKIT_GPU_BLOCK not in source:
        raise RuntimeError("pinned krunkit GPU setup block changed; update the control patch")
    context.write_text(
        source.replace(KRUNKIT_GPU_BLOCK, KRUNKIT_HEADLESS_BLOCK, 1),
        encoding="utf-8",
    )
    return context, source


def vm_failure_details(vm: object) -> str:
    vm_dir = Path.home() / ".vmnet-helper/vms" / str(vm.vm_name)
    sections: list[str] = []
    for name in ("krunkit.command", "krunkit.log", "serial.log"):
        path = vm_dir / name
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            content = f"<unable to read: {error}>"
        if len(content) > 32_000:
            content = content[-32_000:]
            content = "<truncated to final 32000 characters>\n" + content
        sections.append(f"--- {path} ---\n{content.rstrip()}")
    return "\n".join(sections)


def find_vmnet_helper() -> Path:
    candidates: list[Path] = []
    brew = shutil.which("brew")
    if brew:
        result = subprocess.run(
            [brew, "--prefix", "vmnet-helper"], capture_output=True, text=True, check=False
        )
        if result.returncode == 0 and result.stdout.strip():
            prefix = Path(result.stdout.strip())
            candidates.extend([
                prefix / "libexec/vmnet-helper",
                prefix / "bin/vmnet-helper",
            ])
    candidates.append(Path("/opt/vmnet-helper/bin/vmnet-helper"))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(
        "vmnet-helper is not installed; on macOS 26 install it with "
        "`brew tap nirs/vmnet-helper && brew trust nirs/vmnet-helper && brew install vmnet-helper`"
    )


def prepare_krunkit(root: Path, checkout: Path, prefix: Path, timeout: int) -> Path:
    libkrun = root / ".build-deps/libkrun/target/release" / LIBKRUN_DYLIB
    if not libkrun.is_file():
        raise RuntimeError(f"missing {libkrun}; run `mise run libkrun` first")

    lib_dir = prefix / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    for name in (LIBKRUN_DYLIB, "libkrun.1.dylib", "libkrun.dylib"):
        target = lib_dir / name
        if target.exists() or target.is_symlink():
            target.unlink()
        target.symlink_to(libkrun)

    stamp_value = f"{KRUNKIT_COMMIT} {sha256(libkrun)} {KRUNKIT_CONTROL_PATCH}\n"
    stamp = prefix / ".krunkit-control-stamp"
    binary = prefix / "bin/krunkit"
    firmware = prefix / "share/krunkit/KRUN_EFI.silent.fd"
    if not binary.is_file() or not stamp.is_file() or stamp.read_text() != stamp_value:
        context, original_context = patch_krunkit_headless(checkout)
        try:
            subprocess.run(["cargo", "clean"], cwd=checkout, check=False, stdout=subprocess.DEVNULL)
            env = os.environ.copy()
            env["PREFIX"] = str(prefix)
            rpath = "-C link-arg=-Wl,-rpath,@executable_path/../lib"
            env["RUSTFLAGS"] = " ".join(filter(None, [env.get("RUSTFLAGS", "").strip(), rpath]))
            run(["cargo", "build", "--release"], cwd=checkout, timeout=timeout, env=env)
        finally:
            context.write_text(original_context, encoding="utf-8")

        status = run(
            ["git", "-C", str(checkout), "status", "--porcelain=v1", "--untracked-files=all"],
            timeout=timeout,
        ).stdout.strip()
        if status:
            raise RuntimeError(f"krunkit checkout changed during control build:\n{status}")

        source_binary = checkout / "target/release/krunkit"
        source_firmware = checkout / "edk2/KRUN_EFI.silent.fd"
        if not source_binary.is_file() or not source_firmware.is_file():
            raise RuntimeError("krunkit build did not produce the expected binary and firmware")

        binary.parent.mkdir(parents=True, exist_ok=True)
        firmware.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_binary, binary)
        shutil.copy2(source_firmware, firmware)
        binary.chmod(0o755)

        load_commands = run(["otool", "-l", str(binary)], timeout=timeout).stdout
        if "@executable_path/../lib" not in load_commands:
            raise RuntimeError("krunkit control binary is missing its libkrun rpath")
        stamp.write_text(stamp_value, encoding="utf-8")

    entitlements = checkout / "krunkit.entitlements"
    if not entitlements.is_file():
        raise RuntimeError(f"missing krunkit entitlements: {entitlements}")
    run(
        [
            "codesign",
            "--entitlements",
            str(entitlements),
            "--force",
            "-s",
            "-",
            str(binary),
        ],
        timeout=timeout,
    )
    return binary


def ssh(vm_name: str, config: Path, argv: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return run(["ssh", "-F", str(config), vm_name, *argv], timeout=timeout)


def wait_for_ssh(vm: object, config: Path, timeout: int) -> None:
    vm_name = str(vm.vm_name)
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(
                ["ssh", "-F", str(config), "-o", "ConnectTimeout=2", vm_name, "true"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            last = f"SSH readiness probe timed out after {exc.timeout} seconds"
        else:
            if result.returncode == 0:
                return
            last = result.stdout + result.stderr

        try:
            vm.check_running()
        except RuntimeError as error:
            details = vm_failure_details(vm)
            if details:
                raise RuntimeError(f"{error}\n{details}") from error
            raise
        time.sleep(1)
    raise RuntimeError(f"timeout waiting for control VM SSH: {last}")


def create_cidata_iso(vm: object, cidata_module: object, timeout: int) -> str:
    """Create the vmnet-helper cloud-init seed with macOS built-in hdiutil."""
    cidata = Path(cidata_module.store.vm_path(vm.vm_name, "cidata.iso"))
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp)
        (source / "meta-data").write_text(
            yaml.dump(cidata_module.create_meta_data(vm), sort_keys=False),
            encoding="utf-8",
        )
        (source / "user-data").write_text(
            "#cloud-config\n"
            + yaml.dump(cidata_module.create_user_data(vm), sort_keys=False),
            encoding="utf-8",
        )
        (source / "network-config").write_text(
            yaml.dump(cidata_module.create_network_config(vm), sort_keys=False),
            encoding="utf-8",
        )
        if cidata.exists():
            cidata.unlink()
        run(
            [
                "hdiutil",
                "makehybrid",
                "-quiet",
                "-iso",
                "-joliet",
                "-default-volume-name",
                "cidata",
                "-o",
                str(cidata),
                str(source),
            ],
            timeout=timeout,
        )
    return str(cidata)


def prepare_control_disk(vm: object, disks_module: object, timeout: int) -> dict[str, str]:
    """Prepare a writable QCOW2 root disk without requiring qemu-img."""
    image = disks_module.IMAGES[vm.distro][platform.machine()]["image"]
    image_hash = hashlib.sha256(image.encode()).hexdigest()
    cache_dir = Path(disks_module.store.ensure_cache_dir("images", image_hash))
    cached = cache_dir / "control.qcow2"
    if not cached.is_file():
        tmp = cached.with_suffix(".tmp")
        print(f"[vmnet-helper-control] downloading {image}", flush=True)
        try:
            with urllib.request.urlopen(image, timeout=timeout) as response, tmp.open("wb") as stream:
                shutil.copyfileobj(response, stream, length=1024 * 1024)
            tmp.replace(cached)
        finally:
            if tmp.exists():
                tmp.unlink()

    target = Path(disks_module.store.vm_path(vm.vm_name, "disk.qcow2"))
    if not target.is_file():
        clone = subprocess.run(
            ["/bin/cp", "-c", str(cached), str(target)],
            capture_output=True,
            text=True,
            check=False,
        )
        if clone.returncode != 0:
            shutil.copyfile(cached, target)
    return {"image": str(target)}


def mark_root_disk_qcow2(argv: list[str]) -> list[str]:
    """Tell krunkit that the first virtio-blk device is the QCOW2 root disk."""
    command = list(argv)
    prefix = "--device=virtio-blk,path="
    for index, argument in enumerate(command):
        if argument.startswith(prefix):
            command[index] = argument + ",format=qcow2"
            return command
    raise RuntimeError("krunkit control command has no virtio-blk root disk")


def tcp_sample(
    vm_name: str,
    config: Path,
    gateway: str,
    streams: int,
    seconds: int,
    timeout: int,
) -> Sample:
    with streams_bench.SinkServer(gateway) as sink:
        result = ssh(
            vm_name,
            config,
            [
                "python3",
                "-c",
                streams_bench.GUEST_SOURCE,
                gateway,
                str(sink.port),
                str(streams),
                str(seconds),
                str(256 * 1024),
            ],
            max(timeout, seconds + 30),
        )
    data = streams_bench.parse_json_line(result.stdout)
    mib_per_second = float(data["mib_per_second"])
    return Sample(
        streams=streams,
        iteration=0,
        bits_per_second=mib_per_second * MIB * 8,
        mib_per_second=mib_per_second,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--streams", type=parse_streams, default=parse_streams("1,4,8"))
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--warmup-seconds", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--cpus", type=int, default=4)
    parser.add_argument("--memory", type=int, default=2048)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--result-root", type=Path, default=Path("validation-results"))
    args = parser.parse_args()
    if min(args.seconds, args.warmup_seconds, args.iterations, args.cpus, args.memory, args.timeout) <= 0:
        parser.error("durations, iterations, cpus, memory, and timeout must be positive")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("the vmnet-helper control requires Apple Silicon macOS")
    for command in ("git", "cargo", "ssh", "hdiutil", "otool", "codesign"):
        if shutil.which(command) is None:
            parser.error(f"required command not found: {command}")
    if not list((Path.home() / ".ssh").glob("id_*.pub")):
        parser.error("vmnet-helper control VM requires at least one ~/.ssh/id_*.pub key")

    root = Path(__file__).resolve().parent.parent
    deps = root / ".build-deps"
    helper_checkout = deps / "vmnet-helper-control"
    krunkit_checkout = deps / "krunkit-control"
    control_prefix = deps / "krunkit-control-prefix"
    ensure_checkout(helper_checkout, VMNET_HELPER_REPOSITORY, VMNET_HELPER_COMMIT, args.timeout)
    ensure_checkout(krunkit_checkout, KRUNKIT_REPOSITORY, KRUNKIT_COMMIT, args.timeout)
    helper_binary = find_vmnet_helper()
    krunkit_binary = prepare_krunkit(root, krunkit_checkout, control_prefix, args.timeout)

    sys.path.insert(0, str(helper_checkout))
    import testing  # type: ignore[import-not-found]
    import testing.cidata as cidata_module  # type: ignore[import-not-found]
    import testing.disks as disks_module  # type: ignore[import-not-found]
    import testing.helper as helper_module  # type: ignore[import-not-found]

    helper_module.HELPER = str(helper_binary)
    cidata_module.create_iso = lambda vm: create_cidata_iso(vm, cidata_module, args.timeout)
    disks_module.create_disk = lambda vm: prepare_control_disk(vm, disks_module, args.timeout)
    original_krunkit_command = testing.VM.krunkit_command
    testing.VM.krunkit_command = lambda vm: mark_root_disk_qcow2(original_krunkit_command(vm))

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    token = f"{stamp}-{os.getpid()}"
    output = args.result_root / f"vmnet-helper-control-{token}"
    archive = args.result_root / f"container-runtime-krun-vmnet-helper-control-{token}.tar.gz"
    output.mkdir(parents=True, exist_ok=True)
    args.result_root.mkdir(parents=True, exist_ok=True)
    vm_name = f"krun-control-{os.getpid()}"
    helper_log = output / "vmnet-helper.log"
    helper_version = run([str(helper_binary), "--version"], timeout=args.timeout).stdout.strip()
    (output / "krunkit-otool.txt").write_text(
        run(["otool", "-L", str(krunkit_binary)], timeout=args.timeout).stdout,
        encoding="utf-8",
    )
    provenance = root / ".build-deps/libkrun/target/release/native-vmnet.provenance"
    if provenance.is_file():
        shutil.copy2(provenance, output / "libkrun.provenance")

    vm_args = SimpleNamespace(
        vm_name=vm_name,
        operation_mode="shared",
        start_address=None,
        end_address=None,
        subnet_mask=None,
        shared_interface=None,
        network_name=None,
        enable_isolation=False,
        enable_offloading=True,
        stats_interval=1,
        verbose=False,
        driver="krunkit",
        driver_command=str(krunkit_binary),
        cpus=args.cpus,
        memory=args.memory,
        distro="ubuntu",
        dns_servers=["8.8.8.8", "1.1.1.1"],
        ip_address=None,
        busy_poll=False,
    )

    vm_sock = helper_sock = helper = vm = None
    samples: list[Sample] = []
    try:
        vm_sock, helper_sock = testing.socketpair(True)
        helper = testing.Helper(vm_args, fd=helper_sock.fileno(), logfile=str(helper_log))
        helper.start()
        vm = testing.VM(
            vm_args,
            helper.interface[testing.VMNET_MAC_ADDRESS],
            fd=vm_sock.fileno(),
        )
        vm.start()
        ssh_config = Path.home() / ".vmnet-helper/vms" / vm_name / "ssh.config"
        wait_for_ssh(vm, ssh_config, args.timeout)
        ssh(
            vm_name,
            ssh_config,
            [
                "sh",
                "-lc",
                "command -v python3 >/dev/null || "
                "(sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3)",
            ],
            args.timeout,
        )
        gateway = str(helper.interface[testing.VMNET_START_ADDRESS])

        for streams in args.streams:
            warmup = tcp_sample(
                vm_name, ssh_config, gateway, streams, args.warmup_seconds, args.timeout
            )
            print(
                f"[vmnet-helper-control] warmup P{streams}: {warmup.mib_per_second:.1f} MiB/s",
                flush=True,
            )
            for iteration in range(1, args.iterations + 1):
                sample = tcp_sample(vm_name, ssh_config, gateway, streams, args.seconds, args.timeout)
                sample = Sample(
                    streams=sample.streams,
                    iteration=iteration,
                    bits_per_second=sample.bits_per_second,
                    mib_per_second=sample.mib_per_second,
                )
                samples.append(sample)
                print(
                    f"[vmnet-helper-control] P{streams} #{iteration}: "
                    f"{sample.mib_per_second:.1f} MiB/s",
                    flush=True,
                )

        metadata = {
            "direction": "guest_to_host",
            "transport": "krunkit unixgram -> vmnet-helper -> vmnet_write",
            "workload": "repository sustained TCP stream protocol",
            "chunk_kib": 256,
            "offloading": "TSO + checksum",
            "streams": args.streams,
            "seconds": args.seconds,
            "warmup_seconds": args.warmup_seconds,
            "iterations": args.iterations,
            "cpus": args.cpus,
            "memory_mib": args.memory,
            "repository_head": git_head(root),
            "libkrun_head": git_head(root / ".build-deps/libkrun"),
            "libkrun_sha256": sha256(root / ".build-deps/libkrun/target/release" / LIBKRUN_DYLIB),
            "vmnet_helper_commit": VMNET_HELPER_COMMIT,
            "vmnet_helper_binary": str(helper_binary),
            "vmnet_helper_version": helper_version,
            "krunkit_commit": KRUNKIT_COMMIT,
            "krunkit_binary": str(krunkit_binary),
            "platform": platform.platform(),
            "machine": platform.machine(),
        }
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        (output / "samples.json").write_text(
            json.dumps([asdict(sample) for sample in samples], indent=2) + "\n", encoding="utf-8"
        )
        rows = summarize(samples)
        (output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
        with (output / "summary.tsv").open("w", encoding="utf-8") as stream:
            stream.write(
                "streams\tsamples\tmedian_mib_per_second\tp10_mib_per_second\t"
                "p90_mib_per_second\tmin_mib_per_second\tmax_mib_per_second\n"
            )
            for row in rows:
                stream.write(
                    f"{row['streams']}\t{row['samples']}\t{row['median_mib_per_second']:.3f}\t"
                    f"{row['p10_mib_per_second']:.3f}\t{row['p90_mib_per_second']:.3f}\t"
                    f"{row['min_mib_per_second']:.3f}\t{row['max_mib_per_second']:.3f}\n"
                )
    finally:
        if vm is not None:
            vm.stop()
        if helper is not None:
            helper.stop()
        if vm_sock is not None:
            vm_sock.close()
        if helper_sock is not None:
            helper_sock.close()

    with tarfile.open(archive, "w:gz") as tar:
        tar.add(output, arcname=output.name)
    print(f"[vmnet-helper-control] archive: {archive}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
