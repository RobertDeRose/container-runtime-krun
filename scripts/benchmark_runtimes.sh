#!/usr/bin/env bash
set -uo pipefail

RUNTIME_A="container-runtime-linux"
RUNTIME_B="container-runtime-krun"
IMAGE="alpine:3.20"
ITERATIONS=5
RESULT_ROOT="validation-results"
INSTALL_KRUN=0
COMMAND_TIMEOUT_SECONDS=180
CLEANUP_TIMEOUT_SECONDS=30
STARTUP_MEMORY=""
STARTUP_CPUS=""
STARTUP_ONLY=0
STARTUP_CAP_ADD=()

usage(){ cat <<'USAGE'
Usage: scripts/benchmark_runtimes.sh [options]

Collect repeatable, non-gating comparisons between Apple's default runtime and
container-runtime-krun. Raw samples are retained; no performance threshold is
enforced.

Options:
  --install-krun      Build/install krun and restart Apple Container first.
  --runtime-a NAME    Baseline runtime (default: container-runtime-linux).
  --runtime-b NAME    Comparison runtime (default: container-runtime-krun).
  --image IMAGE       Warm test image (default: alpine:3.20).
  --iterations N      Samples per repeated metric (default: 5).
  --startup-memory N  Override memory only for startup samples (for example: 512m or 2g).
  --startup-cpus N    Override CPU count only for startup samples.
  --startup-only      Collect only paired startup samples.
  --startup-cap-add C Add Linux capability C to startup containers (repeatable).
  --command-timeout N Liveness deadline per container/build command in seconds (default: 180).
  --result-root DIR   Output directory (default: validation-results).
  -h, --help          Show help.
USAGE
}
while (($#)); do
  case "$1" in
    --install-krun) INSTALL_KRUN=1; shift;;
    --runtime-a) RUNTIME_A="${2:?missing runtime}"; shift 2;;
    --runtime-b) RUNTIME_B="${2:?missing runtime}"; shift 2;;
    --image) IMAGE="${2:?missing image}"; shift 2;;
    --iterations) ITERATIONS="${2:?missing iterations}"; shift 2;;
    --startup-memory) STARTUP_MEMORY="${2:?missing startup memory}"; shift 2;;
    --startup-cpus) STARTUP_CPUS="${2:?missing startup CPU count}"; shift 2;;
    --startup-only) STARTUP_ONLY=1; shift;;
    --startup-cap-add) STARTUP_CAP_ADD+=("${2:?missing startup capability}"); shift 2;;
    --command-timeout) COMMAND_TIMEOUT_SECONDS="${2:?missing command timeout}"; shift 2;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "--iterations must be positive" >&2; exit 2; }
[[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "--command-timeout must be positive" >&2; exit 2; }
[[ -z "$STARTUP_CPUS" || "$STARTUP_CPUS" =~ ^[1-9][0-9]*$ ]] || { echo "--startup-cpus must be positive" >&2; exit 2; }
for c in container python3 git mise ps dd; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="kb-${STAMP}-$$"
OUT="$RESULT_ROOT/benchmark-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-benchmark-${STAMP}-$$.tar.gz"
mkdir -p "$OUT"
SAMPLES="$OUT/samples.tsv"
printf 'runtime\tmetric\titeration\tduration_ms\tstatus\n' >"$SAMPLES"
FAILED=0
ACTIVE_IDS=()
VOLUMES=()
LOG_STREAM_PID=""
APP_ROOT=""
exec 3>&2

progress(){ printf '[benchmark] %s\n' "$*" >&3; }

track_id(){ ACTIVE_IDS+=("$1"); }
untrack_id(){
  local target="$1" id
  local kept=()
  for id in "${ACTIVE_IDS[@]}"; do
    [[ "$id" == "$target" ]] || kept+=("$id")
  done
  ACTIVE_IDS=("${kept[@]}")
}
runtime_key(){ printf '%s' "${1//[^A-Za-z0-9]/-}"; }

start_lifecycle_stream(){
  [[ -x /usr/bin/log ]] || return 0
  /usr/bin/log stream --style syslog --level info \
    --predicate 'subsystem == "com.apple.container" AND category == "RuntimeKrun"' \
    >"$OUT/runtime-lifecycle-stream.txt" 2>&1 &
  LOG_STREAM_PID=$!
  sleep 1
}

stop_lifecycle_stream(){
  [[ -n "$LOG_STREAM_PID" ]] || return 0
  sleep 1
  kill "$LOG_STREAM_PID" >/dev/null 2>&1 || true
  wait "$LOG_STREAM_PID" 2>/dev/null || true
  LOG_STREAM_PID=""
  grep -F "$PREFIX" "$OUT/runtime-lifecycle-stream.txt" 2>/dev/null \
    | grep -F 'runtime lifecycle' >"$OUT/runtime-lifecycle.txt" || true
}

capture_krun_helper_log(){
  local id="$1" iteration="$2"
  local source
  [[ -n "$APP_ROOT" ]] || return 0
  source="$APP_ROOT/containers/$id/krun-vmm.log"
  [[ -r "$source" ]] || return 0
  cp "$source" "$OUT/container-runtime-krun-startup-$iteration-krun-vmm.log"
}

capture_host_kernel_symbols(){
  local kernel_arch kernel_link kernel_path
  [[ -n "$APP_ROOT" ]] || return 0

  case "$(uname -m)" in
    arm64|aarch64) kernel_arch="arm64";;
    x86_64) kernel_arch="amd64";;
    *) kernel_arch="$(uname -m)";;
  esac

  kernel_link="$APP_ROOT/kernels/default.kernel-$kernel_arch"
  {
    echo "kernel_link=$kernel_link"
    ls -la "$APP_ROOT/kernels" 2>&1 || true
  } >"$OUT/host-kernel-layout.txt"
  [[ -e "$kernel_link" ]] || return 0

  kernel_path="$(python3 - "$kernel_link" <<'PY_KERNEL_PATH'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY_KERNEL_PATH
)"
  {
    echo "kernel_path=$kernel_path"
    file "$kernel_path" 2>&1 || true
    shasum -a 256 "$kernel_path" 2>&1 || true
  } >"$OUT/host-kernel-info.txt"

  if command -v xcrun >/dev/null 2>&1; then
    xcrun llvm-nm -n "$kernel_path" >"$OUT/host-kernel-symbols.txt" \
      2>"$OUT/host-kernel-symbols.err" || true
  fi

  python3 - "$kernel_path" >"$OUT/host-kernel-patching-windows.txt" <<'PY_KERNEL_WINDOWS'
import pathlib
import sys

kernel = pathlib.Path(sys.argv[1])
data = kernel.read_bytes()
windows = (
    ("ftrace_init_nop", 0x24C90, 0x100),
    ("aarch64_insn_write_literal_u64", 0xD789B0, 0xC0),
    ("__aarch64_insn_write", 0xD86488, 0xC0),
    ("aarch64_insn_patch_text_nosync", 0xD866F0, 0x80),
)

for name, offset, length in windows:
    print(f"--- {name} image_offset=0x{offset:x} length=0x{length:x} ---")
    end = offset + length
    if end > len(data):
        print(f"error=range_out_of_bounds kernel_size=0x{len(data):x}")
        continue
    for pos in range(offset, end, 4):
        word = int.from_bytes(data[pos:pos + 4], "little")
        print(f"offset=0x{pos:x} word=0x{word:08x}")
PY_KERNEL_WINDOWS
}

resolve_guest_kernel_addresses(){
  local id="$1" label="$2" targets_csv="$3" output="$4" error_output="$5"
  [[ -n "$targets_csv" ]] || return 0

  run_bounded "$COMMAND_TIMEOUT_SECONDS" \
    container exec "$id" awk -v "label=$label" -v "targets=$targets_csv" '
      BEGIN {
        count = split(targets, target, ",")
      }
      {
        addr = tolower($1)
        if (length(addr) != 16) {
          next
        }
        for (i = 1; i <= count; i++) {
          if (addr <= target[i] && (best[i] == "" || addr >= best[i])) {
            best[i] = addr
            type[i] = $2
            name[i] = $3
          }
        }
      }
      END {
        for (i = 1; i <= count; i++) {
          printf "%s=0x%s symbol_addr=0x%s type=%s symbol=%s\n", \
            label, target[i], best[i], type[i], name[i]
        }
      }
    ' /proc/kallsyms \
    >"$output" 2>"$error_output" || true
}

capture_guest_kernel_symbols(){
  local id="$1" iteration="$2" prefix helper_log pcs_csv lrs_csv
  prefix="$OUT/container-runtime-krun-startup-$iteration-guest-kernel"
  helper_log="$OUT/container-runtime-krun-startup-$iteration-krun-vmm.log"

  {
    echo '--- uname ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" uname -a || true
    echo '--- version ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" cat /proc/version || true
    echo '--- cmdline ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" cat /proc/cmdline || true
    echo '--- kptr_restrict ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" cat /proc/sys/kernel/kptr_restrict || true
    echo '--- perf_event_paranoid ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" cat /proc/sys/kernel/perf_event_paranoid || true
    echo '--- capabilities ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" sh -c \
      "grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb):' /proc/self/status" || true
    echo '--- ftrace ---'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" sh -c '
      for path in /sys/kernel/tracing/available_filter_functions /sys/kernel/debug/tracing/available_filter_functions; do
        if [ -r "$path" ]; then
          printf "available_filter_functions_path=%s\n" "$path"
          wc -l < "$path" | sed "s/^/available_filter_functions_count=/"
          break
        fi
      done
      if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz 2>/dev/null \
          | grep -E "^CONFIG_(FUNCTION_TRACER|DYNAMIC_FTRACE|DYNAMIC_FTRACE_WITH_ARGS|DYNAMIC_FTRACE_WITH_CALL_OPS|ARM64_BTI_KERNEL)=" \
          || true
      fi
    ' || true
  } >"$prefix-info.txt" 2>&1

  [[ -r "$helper_log" ]] || return 0
  pcs_csv="$(
    sed -n 's/.*libkrun hvf pc sample .* pc=0x\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' "$helper_log" \
      | tr 'A-F' 'a-f' \
      | sort -u \
      | paste -sd, -
  )"
  lrs_csv="$(
    sed -n 's/.*libkrun hvf pc sample .* lr=0x\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' "$helper_log" \
      | tr 'A-F' 'a-f' \
      | sort -u \
      | paste -sd, -
  )"

  if [[ -n "$pcs_csv" ]]; then
    printf '%s\n' "$pcs_csv" | tr ',' '\n' | sed 's/^/0x/' >"$prefix-pcs.txt"
    resolve_guest_kernel_addresses \
      "$id" pc "$pcs_csv" "$prefix-symbols.txt" "$prefix-symbols.err"
  fi

  if [[ -n "$lrs_csv" ]]; then
    printf '%s\n' "$lrs_csv" | tr ',' '\n' | sed 's/^/0x/' >"$prefix-lrs.txt"
    resolve_guest_kernel_addresses \
      "$id" lr "$lrs_csv" "$prefix-lr-symbols.txt" "$prefix-lr-symbols.err"
  fi
}

run_bounded(){
  local timeout_seconds="$1"
  shift
  python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout, *cmd = sys.argv[1:]
proc = subprocess.Popen(cmd, start_new_session=True)

def terminate_group():
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()

try:
    raise SystemExit(proc.wait(timeout=int(timeout)))
except subprocess.TimeoutExpired:
    print(f"command timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
    terminate_group()
    raise SystemExit(124)
except KeyboardInterrupt:
    terminate_group()
    raise SystemExit(130)
PY
}

cleanup(){
  local id v
  stop_lifecycle_stream
  for id in "${ACTIVE_IDS[@]}"; do
    run_bounded "$CLEANUP_TIMEOUT_SECONDS" container delete --force "$id" >/dev/null 2>&1 || true
  done
  for v in "${VOLUMES[@]}"; do
    run_bounded "$CLEANUP_TIMEOUT_SECONDS" container volume delete "$v" >/dev/null 2>&1 || true
  done
}
archive_results(){ tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"; progress "archive: $ARCHIVE"; }
finish_results(){
  stop_lifecycle_stream
  python3 - "$SAMPLES" >"$OUT/summary.tsv" <<'PY_SUMMARY'
import csv,math,statistics,sys
from collections import defaultdict
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
g=defaultdict(list)
for r in rows:
    if int(r['status'])==0: g[(r['runtime'],r['metric'])].append(float(r['duration_ms']))
print('runtime\tmetric\tn\tmin_ms\tmedian_ms\tp95_ms\tmax_ms\tmean_ms')
for (runtime,metric),xs in sorted(g.items()):
    ys=sorted(xs); p95=ys[max(0, math.ceil(.95*len(ys))-1)]
    print(f'{runtime}\t{metric}\t{len(ys)}\t{min(ys):.3f}\t{statistics.median(ys):.3f}\t{p95:.3f}\t{max(ys):.3f}\t{statistics.mean(ys):.3f}')
PY_SUMMARY
  cat "$OUT/summary.tsv"
  if awk -F '\t' 'NR > 1 && $5 != 0 { bad=1 } END { exit bad ? 0 : 1 }' "$SAMPLES"; then
    FAILED=1
    echo "one or more benchmark commands failed; see samples.tsv" >&2
  fi
  archive_results
  trap - EXIT INT TERM
  exit "$FAILED"
}
interrupt(){
  local status="$1"
  trap - EXIT INT TERM
  progress "interrupted; cleaning up and preserving partial results"
  cleanup
  archive_results || true
  exit "$status"
}
run_required(){
  local name="$1"
  local status
  shift
  progress "$name"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    run_bounded "$COMMAND_TIMEOUT_SECONDS" "$@"
    status=$?
    printf '\nexit_status=%d\n' "$status"
  } >"$OUT/$name.txt" 2>&1
  if ((status == 0)); then
    return 0
  fi
  printf 'required step failed: %s (exit %d)\n' "$name" "$status" >"$OUT/FAILURE.txt"
  archive_results
  exit 1
}
trap cleanup EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM

capture_libkrun_provenance(){
  local source_dir=".build-deps/libkrun"
  local install_root provenance

  if git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "libkrun_git_head=$(git -C "$source_dir" rev-parse HEAD)" >>"$OUT/environment.txt"
    git -C "$source_dir" status --short >"$OUT/libkrun-git-status.txt"
  else
    echo "libkrun_git_head=" >>"$OUT/environment.txt"
    printf 'libkrun checkout unavailable\n' >"$OUT/libkrun-git-status.txt"
  fi

  install_root="${INSTALL_ROOT:-$(python3 scripts/install_root.py 2>/dev/null || true)}"
  [[ -n "$install_root" ]] || return 0
  provenance="$install_root/libexec/container-plugins/container-runtime-krun/lib/libkrun.provenance"
  [[ -r "$provenance" ]] || return 0
  cp "$provenance" "$OUT/libkrun.provenance"
}

time_cmd(){
  local runtime="$1" metric="$2" iteration="$3"; shift 3
  progress "$runtime: $metric sample $iteration"
  python3 - "$SAMPLES" "$runtime" "$metric" "$iteration" "$COMMAND_TIMEOUT_SECONDS" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

out, runtime, metric, iteration, timeout, *cmd = sys.argv[1:]
start = time.perf_counter_ns()
proc = subprocess.Popen(cmd, start_new_session=True)

def terminate_group():
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()

try:
    status = proc.wait(timeout=int(timeout))
except subprocess.TimeoutExpired:
    status = 124
    print(f"command timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
    terminate_group()
except KeyboardInterrupt:
    terminate_group()
    raise SystemExit(130)
ms = (time.perf_counter_ns() - start) / 1_000_000
with open(out, 'a') as f:
    f.write(f"{runtime}\t{metric}\t{iteration}\t{ms:.3f}\t{status}\n")
raise SystemExit(status)
PY
}

{
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "runtime_a=$RUNTIME_A"
  echo "runtime_b=$RUNTIME_B"
  echo "image=$IMAGE"
  echo "iterations=$ITERATIONS"
  echo "startup_memory=$STARTUP_MEMORY"
  echo "startup_cpus=$STARTUP_CPUS"
  echo "startup_only=$STARTUP_ONLY"
  echo "startup_cap_add=$(IFS=,; echo "${STARTUP_CAP_ADD[*]}")"
  echo "ordering=paired-ab-ba"
  echo "startup_scope=detached-start-only"
  echo "volume_scope=persistent-container-exec"
  echo "command_timeout_seconds=$COMMAND_TIMEOUT_SECONDS"
} >"$OUT/environment.txt"

if ((INSTALL_KRUN)); then
  run_required mise-doctor mise run doctor
  run_required mise-check mise run check
  run_required mise-test mise run test
  run_required mise-install mise run install
  run_required system-stop container system stop
  run_required system-start container system start
fi

capture_libkrun_provenance

STARTUP_MEMORY_ARGS=()
if [[ -n "$STARTUP_MEMORY" ]]; then
  STARTUP_MEMORY_ARGS=(--memory "$STARTUP_MEMORY")
fi
STARTUP_CPU_ARGS=()
if [[ -n "$STARTUP_CPUS" ]]; then
  STARTUP_CPU_ARGS=(--cpus "$STARTUP_CPUS")
fi
STARTUP_CAP_ARGS=()
for cap in "${STARTUP_CAP_ADD[@]}"; do
  STARTUP_CAP_ARGS+=(--cap-add "$cap")
done

run_bounded "$COMMAND_TIMEOUT_SECONDS" container system status --format json \
  >"$OUT/system-status-before.json" 2>&1 || true
APP_ROOT="$(python3 - "$OUT/system-status-before.json" <<'PY'
import json
import sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("")
else:
    print(data.get("appRoot") or (data.get("paths") or {}).get("appRoot") or "")
PY
)"
echo "app_root=$APP_ROOT" >>"$OUT/environment.txt"
capture_host_kernel_symbols

start_lifecycle_stream
progress "results: $OUT"
progress "warming image and runtime control planes"

for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  warm_id="$PREFIX-warm-$(runtime_key "$runtime")"
  track_id "$warm_id"
  run_required "warm-$(runtime_key "$runtime")" \
    container run --rm --name "$warm_id" --runtime "$runtime" --network none \
      "${STARTUP_MEMORY_ARGS[@]}" "${STARTUP_CPU_ARGS[@]}" "${STARTUP_CAP_ARGS[@]}" "$IMAGE" true
  untrack_id "$warm_id"
done

dd if=/dev/zero of="$OUT/copy-source.bin" bs=1M count=16 >/dev/null 2>&1

progress "paired startup samples"
for ((i=1; i<=ITERATIONS; i++)); do
  if ((i % 2 == 1)); then
    first="$RUNTIME_A"; second="$RUNTIME_B"
  else
    first="$RUNTIME_B"; second="$RUNTIME_A"
  fi
  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    id="$PREFIX-${key}-start-$i"
    track_id "$id"
    time_cmd "$runtime" startup "$i" \
      container run -d --name "$id" --runtime "$runtime" --network none \
      "${STARTUP_MEMORY_ARGS[@]}" "${STARTUP_CPU_ARGS[@]}" "${STARTUP_CAP_ARGS[@]}" "$IMAGE" \
      sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
      >"$OUT/${key}-startup-$i.txt" 2>&1 || true
    if [[ "$runtime" == "$RUNTIME_B" ]]; then
      capture_krun_helper_log "$id" "$i"
      capture_guest_kernel_symbols "$id" "$i"
    fi
    if ! run_bounded "$CLEANUP_TIMEOUT_SECONDS" container delete --force "$id" \
        >"$OUT/${key}-startup-$i-delete.txt" 2>&1; then
      FAILED=1
    fi
    untrack_id "$id"
  done
done

if ((STARTUP_ONLY)); then
  finish_results
fi

progress "starting persistent benchmark containers"
for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  key="$(runtime_key "$runtime")"
  id="$PREFIX-${key}-live"
  track_id "$id"
  if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" \
      container run -d --name "$id" --runtime "$runtime" --network none "$IMAGE" \
      sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
      >"$OUT/${key}-live-start.txt" 2>&1; then
    FAILED=1
  fi
  /bin/ps -axo pid=,ppid=,rss=,vsz=,command= | grep -F -- "$id" \
    >"$OUT/${key}-processes-idle.txt" 2>&1 || true
done

for ((i=1; i<=ITERATIONS; i++)); do
  if ((i % 2 == 1)); then
    first="$RUNTIME_A"; second="$RUNTIME_B"
  else
    first="$RUNTIME_B"; second="$RUNTIME_A"
  fi

  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    id="$PREFIX-${key}-live"
    time_cmd "$runtime" exec "$i" container exec "$id" true \
      >"$OUT/${key}-exec-$i.txt" 2>&1 || true
  done

  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    id="$PREFIX-${key}-live"
    time_cmd "$runtime" cpu "$i" container exec "$id" sh -c \
      'dd if=/dev/zero bs=1M count=64 2>/dev/null | sha256sum >/dev/null' \
      >"$OUT/${key}-cpu-$i.txt" 2>&1 || true
  done

  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    id="$PREFIX-${key}-live"
    time_cmd "$runtime" copy_in "$i" container copy "$OUT/copy-source.bin" "$id:/copy-$i.bin" \
      >"$OUT/${key}-copy-in-$i.txt" 2>&1 || true
  done

  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    id="$PREFIX-${key}-live"
    time_cmd "$runtime" copy_out "$i" container copy "$id:/copy-$i.bin" "$OUT/${key}-copy-out-$i.bin" \
      >"$OUT/${key}-copy-out-$i.txt" 2>&1 || true
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" rm -f "/copy-$i.bin" >/dev/null 2>&1 || true
    rm -f "$OUT/${key}-copy-out-$i.bin"
  done
done

# Record reclaimability without turning host RSS behavior into a pass/fail threshold.
for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  key="$(runtime_key "$runtime")"
  mem="$PREFIX-${key}-memory"
  track_id "$mem"
  progress "$runtime: memory reclaimability observation"
  if run_bounded "$COMMAND_TIMEOUT_SECONDS" \
      container run -d --name "$mem" --runtime "$runtime" --network none --memory 1920M --shm-size 1200M \
      "$IMAGE" sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' >"$OUT/${key}-memory-start.txt" 2>&1; then
    if run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$mem" sh -c \
        'dd if=/dev/urandom of=/dev/shm/reclaim.bin bs=1M count=1024 >/dev/null 2>&1; sync' \
        >"$OUT/${key}-memory-allocate.txt" 2>&1; then
      {
        echo '--- held ---'; vm_stat; /usr/bin/memory_pressure 2>/dev/null || true
        /bin/ps -axo pid=,ppid=,rss=,vsz=,command= | grep -F -- "$mem" || true
      } >"$OUT/${key}-memory-host-held.txt" 2>&1
      if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$mem" rm -f /dev/shm/reclaim.bin \
          >"$OUT/${key}-memory-release.txt" 2>&1; then
        FAILED=1
      fi
      sleep 10
      {
        echo '--- released+10s ---'; vm_stat; /usr/bin/memory_pressure 2>/dev/null || true
        /bin/ps -axo pid=,ppid=,rss=,vsz=,command= | grep -F -- "$mem" || true
      } >"$OUT/${key}-memory-host-released.txt" 2>&1
    else
      FAILED=1
    fi
  else
    FAILED=1
  fi
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container stop "$mem" >/dev/null 2>&1 || true
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete "$mem" >/dev/null 2>&1 || true
  untrack_id "$mem"
done

progress "starting persistent volume benchmark containers"
for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  key="$(runtime_key "$runtime")"
  vol="$PREFIX-${key}-volume"
  vid="$PREFIX-${key}-volume-live"
  VOLUMES+=("$vol")
  track_id "$vid"
  if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" container volume create "$vol" \
      >"$OUT/${key}-volume-create.txt" 2>&1; then
    FAILED=1
  fi
  if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" \
      container run -d --name "$vid" --runtime "$runtime" --network none \
      -v "$vol:/bench" "$IMAGE" sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
      >"$OUT/${key}-volume-container-start.txt" 2>&1; then
    FAILED=1
  fi
done

for ((i=1; i<=ITERATIONS; i++)); do
  if ((i % 2 == 1)); then
    first="$RUNTIME_A"; second="$RUNTIME_B"
  else
    first="$RUNTIME_B"; second="$RUNTIME_A"
  fi
  for runtime in "$first" "$second"; do
    key="$(runtime_key "$runtime")"
    vid="$PREFIX-${key}-volume-live"
    time_cmd "$runtime" volume_write "$i" container exec "$vid" sh -c \
      'dd if=/dev/zero of=/bench/data.bin bs=1M count=64 >/dev/null 2>&1; sync; rm -f /bench/data.bin' \
      >"$OUT/${key}-volume-$i.txt" 2>&1 || true
  done
done

for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  key="$(runtime_key "$runtime")"
  vol="$PREFIX-${key}-volume"
  vid="$PREFIX-${key}-volume-live"
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container stop "$vid" \
    >"$OUT/${key}-volume-container-stop.txt" 2>&1 || FAILED=1
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete "$vid" \
    >"$OUT/${key}-volume-container-delete.txt" 2>&1 || FAILED=1
  untrack_id "$vid"
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container volume delete "$vol" \
    >"$OUT/${key}-volume-delete.txt" 2>&1 || FAILED=1
done

for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  key="$(runtime_key "$runtime")"
  id="$PREFIX-${key}-live"
  time_cmd "$runtime" stop 1 container stop "$id" >"$OUT/${key}-stop.txt" 2>&1 || true
  time_cmd "$runtime" delete 1 container delete "$id" >"$OUT/${key}-delete.txt" 2>&1 || true
  untrack_id "$id"
done

finish_results
