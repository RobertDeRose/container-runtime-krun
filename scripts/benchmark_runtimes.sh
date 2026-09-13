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
    --command-timeout) COMMAND_TIMEOUT_SECONDS="${2:?missing command timeout}"; shift 2;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "--iterations must be positive" >&2; exit 2; }
[[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "--command-timeout must be positive" >&2; exit 2; }
for c in container python3 git make ps dd; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done

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
exec 3>&2

progress(){ printf '[benchmark] %s\n' "$*" >&3; }

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
  for id in "${ACTIVE_IDS[@]}"; do
    run_bounded "$CLEANUP_TIMEOUT_SECONDS" container delete --force "$id" >/dev/null 2>&1 || true
  done
  for v in "${VOLUMES[@]}"; do
    run_bounded "$CLEANUP_TIMEOUT_SECONDS" container volume delete "$v" >/dev/null 2>&1 || true
  done
}
archive_results(){ tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"; progress "archive: $ARCHIVE"; }
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
  echo "command_timeout_seconds=$COMMAND_TIMEOUT_SECONDS"
} >"$OUT/environment.txt"

if ((INSTALL_KRUN)); then
  run_required make-doctor make doctor
  run_required make-check make check
  run_required make-test make test
  run_required make-install make install
  run_required system-stop container system stop
  run_required system-start container system start
fi

progress "results: $OUT"
progress "warming image and runtime control planes"

# Warm the image/control plane before collecting samples.
for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  warm_id="$PREFIX-warm-${runtime##*-}"
  ACTIVE_IDS+=("$warm_id")
  run_required "warm-${runtime##*-}" \
    container run --rm --name "$warm_id" --runtime "$runtime" --network none "$IMAGE" true
done

dd if=/dev/zero of="$OUT/copy-source.bin" bs=1M count=16 >/dev/null 2>&1

for runtime in "$RUNTIME_A" "$RUNTIME_B"; do
  progress "benchmarking $runtime"
  key="${runtime//[^A-Za-z0-9]/-}"
  for ((i=1; i<=ITERATIONS; i++)); do
    id="$PREFIX-${key}-start-$i"
    time_cmd "$runtime" startup "$i" container run --rm --name "$id" --runtime "$runtime" --network none "$IMAGE" true \
      >"$OUT/${key}-startup-$i.txt" 2>&1 || true
  done

  id="$PREFIX-${key}-live"
  ACTIVE_IDS+=("$id")
  progress "$runtime: starting live benchmark container"
  if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" \
      container run -d --name "$id" --runtime "$runtime" --network none "$IMAGE" \
      sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
      >"$OUT/${key}-live-start.txt" 2>&1; then
    FAILED=1
    continue
  fi

  /bin/ps -axo pid=,ppid=,rss=,vsz=,command= | grep -F -- "$id" >"$OUT/${key}-processes-idle.txt" 2>&1 || true
  for ((i=1; i<=ITERATIONS; i++)); do
    time_cmd "$runtime" exec "$i" container exec "$id" true >"$OUT/${key}-exec-$i.txt" 2>&1 || true
    time_cmd "$runtime" cpu "$i" container exec "$id" sh -c \
      'dd if=/dev/zero bs=1M count=64 2>/dev/null | sha256sum >/dev/null' >"$OUT/${key}-cpu-$i.txt" 2>&1 || true
    time_cmd "$runtime" copy_in "$i" container copy "$OUT/copy-source.bin" "$id:/copy-$i.bin" \
      >"$OUT/${key}-copy-in-$i.txt" 2>&1 || true
    time_cmd "$runtime" copy_out "$i" container copy "$id:/copy-$i.bin" "$OUT/${key}-copy-out-$i.bin" \
      >"$OUT/${key}-copy-out-$i.txt" 2>&1 || true
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container exec "$id" rm -f "/copy-$i.bin" >/dev/null 2>&1 || true
    rm -f "$OUT/${key}-copy-out-$i.bin"
  done

  # Record reclaimability without turning host RSS behavior into a pass/fail threshold.
  mem="$PREFIX-${key}-memory"
  ACTIVE_IDS+=("$mem")
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

  vol="$PREFIX-${key}-volume"
  VOLUMES+=("$vol")
  progress "$runtime: volume I/O samples"
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container volume create "$vol" >"$OUT/${key}-volume-create.txt" 2>&1 || true
  for ((i=1; i<=ITERATIONS; i++)); do
    vid="$PREFIX-${key}-volume-$i"
    time_cmd "$runtime" volume_write "$i" container run --rm --name "$vid" --runtime "$runtime" --network none \
      -v "$vol:/bench" "$IMAGE" sh -c 'dd if=/dev/zero of=/bench/data.bin bs=1M count=64 >/dev/null 2>&1; sync; rm -f /bench/data.bin' \
      >"$OUT/${key}-volume-$i.txt" 2>&1 || true
  done
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container volume delete "$vol" >"$OUT/${key}-volume-delete.txt" 2>&1 || true

  time_cmd "$runtime" stop 1 container stop "$id" >"$OUT/${key}-stop.txt" 2>&1 || true
  time_cmd "$runtime" delete 1 container delete "$id" >"$OUT/${key}-delete.txt" 2>&1 || true
done

python3 - "$SAMPLES" >"$OUT/summary.tsv" <<'PY'
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
PY
cat "$OUT/summary.tsv"

if awk -F '\t' 'NR > 1 && $5 != 0 { bad=1 } END { exit bad ? 0 : 1 }' "$SAMPLES"; then
  FAILED=1
  echo "one or more benchmark commands failed; see samples.tsv" >&2
fi

archive_results
trap - EXIT INT TERM
exit "$FAILED"
