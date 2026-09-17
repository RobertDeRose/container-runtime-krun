#!/usr/bin/env bash
set -euo pipefail

RUNTIME_A="container-runtime-linux"
RUNTIME_B="container-runtime-krun"
IMAGE="alpine:3.20"
RESULT_ROOT="validation-results"
TRACE_MAX_DURATION="20s"
COMMAND_TIMEOUT_SECONDS=60
POST_START_DELAY_SECONDS="0.25"

usage() {
  cat <<'USAGE'
Usage: scripts/profile_runtime_cpu.sh [options]

Capture four independent CPU Profiler recordings for Apple/VZ and
container-runtime-krun startup in ABBA order. Each container is created before
its trace starts, only one VM is alive in each trace, and tracing stops shortly
after that startup completes.

The desired krun/libkrun build must already be installed. Use
scripts/profile_hvf_startup.sh --install-krun first when rebuilding it.

Options:
  --runtime-a NAME          Baseline runtime (default: container-runtime-linux).
  --runtime-b NAME          Comparison runtime (default: container-runtime-krun).
  --image IMAGE             Test image (default: alpine:3.20).
  --trace-max-duration TIME Safety limit for each CPU profile (default: 20s).
  --post-start-delay SEC    Delay before ending a successful trace (default: 0.25).
  --command-timeout N       Container command timeout in seconds (default: 60).
  --result-root DIR         Output directory (default: validation-results).
  -h, --help                Show help.
USAGE
}

while (($#)); do
  case "$1" in
    --runtime-a) RUNTIME_A="${2:?missing runtime-a}"; shift 2;;
    --runtime-b) RUNTIME_B="${2:?missing runtime-b}"; shift 2;;
    --image) IMAGE="${2:?missing image}"; shift 2;;
    --trace-max-duration) TRACE_MAX_DURATION="${2:?missing trace max duration}"; shift 2;;
    --post-start-delay) POST_START_DELAY_SECONDS="${2:?missing post-start delay}"; shift 2;;
    --command-timeout) COMMAND_TIMEOUT_SECONDS="${2:?missing command timeout}"; shift 2;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

for command in container xcrun notifyutil python3 tar; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done
xcrun --find xctrace >/dev/null
[[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "--command-timeout must be positive" >&2
  exit 2
}
python3 - "$POST_START_DELAY_SECONDS" <<'PY_DELAY'
import sys
value = float(sys.argv[1])
if value < 0:
    raise SystemExit("--post-start-delay must be non-negative")
PY_DELAY
export PAGER=cat GIT_PAGER=cat

run_bounded() {
  local timeout_seconds="$1"
  shift
  python3 - "$timeout_seconds" "$@" <<'PY_TIMEOUT'
import os
import signal
import subprocess
import sys

timeout, *cmd = sys.argv[1:]
proc = subprocess.Popen(cmd, start_new_session=True)

def terminate(sig=None, _frame=None):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if sig is not None:
        raise SystemExit(128 + sig)

signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGTERM, terminate)
try:
    raise SystemExit(proc.wait(timeout=int(timeout)))
except subprocess.TimeoutExpired:
    print(f"command timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
    terminate()
    raise SystemExit(124)
PY_TIMEOUT
}

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="cpu-${STAMP}-$$"
OUT="$RESULT_ROOT/cpu-profile-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-cpu-profile-${STAMP}-$$.tar.gz"
TRACE_PID=""
NOTIFY_PID=""
IDS=()
mkdir -p "$OUT"

cleanup() {
  local id
  set +e
  for id in "${IDS[@]}"; do
    run_bounded 10 container delete --force "$id" >/dev/null 2>&1 || true
  done
  [[ -z "$NOTIFY_PID" ]] || kill "$NOTIFY_PID" >/dev/null 2>&1 || true
  [[ -z "$TRACE_PID" ]] || kill -INT "$TRACE_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'trap - INT TERM; cleanup; exit 130' INT
trap 'trap - INT TERM; cleanup; exit 143' TERM

container system status --format json >"$OUT/system-status.json"
APP_ROOT="$(python3 - "$OUT/system-status.json" <<'PY_ROOT'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get("appRoot") or (data.get("paths") or {}).get("appRoot") or "")
PY_ROOT
)"

record_event() {
  local run_name="$1"
  local label="$2"
  local event="$3"
  python3 - "$run_name" "$label" "$event" >>"$OUT/timeline.tsv" <<'PY_EVENT'
import sys
import time
print(*sys.argv[1:], time.time_ns(), time.monotonic_ns(), sep="\t")
PY_EVENT
}

capture_krun_log() {
  local id="$1"
  local prefix="$2"
  local bundle="$APP_ROOT/containers/$id"
  [[ -r "$bundle/krun-vmm.log" ]] || return 0
  cp "$bundle/krun-vmm.log" "$OUT/${prefix}-krun-vmm.log"
}

create_case() {
  local id="$1"
  local runtime="$2"
  local prefix="$3"
  run_bounded "$COMMAND_TIMEOUT_SECONDS" \
    container create --name "$id" --runtime "$runtime" --network none "$IMAGE" \
      sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
    >"$OUT/${prefix}-create.txt" 2>&1
  IDS+=("$id")
}

finish_case() {
  local id="$1"
  local prefix="$2"
  capture_krun_log "$id" "$prefix"
  run_bounded 5 container inspect "$id" >"$OUT/${prefix}-inspect.txt" 2>&1 || true
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete --force "$id" \
    >"$OUT/${prefix}-delete.txt" 2>&1 || true
  sleep 0.25
}

export_profile() {
  local trace="$1"
  local prefix="$2"
  local runtime="$3"
  local toc="$OUT/${prefix}-toc.xml"
  local profile="$OUT/${prefix}-cpu-profile.xml"

  xcrun xctrace export --input "$trace" --toc --output "$toc" \
    >"$OUT/${prefix}-export-toc.txt" 2>&1
  xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/processes' \
    --output "$OUT/${prefix}-processes.xml" >"$OUT/${prefix}-export-processes.txt" 2>&1

  grep -Fq 'schema="cpu-profile"' "$toc" || {
    echo "CPU Profiler trace does not expose cpu-profile data: $trace" >&2
    return 1
  }
  xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="cpu-profile"]' \
    --output "$profile" >"$OUT/${prefix}-export-cpu-profile.txt" 2>&1

  if [[ "$runtime" == "$RUNTIME_B" ]]; then
    grep -Eq 'container-krun-vmm-helper|fc_vcpu' "$profile" "$OUT/${prefix}-processes.xml" || {
      echo "krun helper/vCPU samples missing from $trace" >&2
      return 1
    }
  else
    grep -Eq 'container-runtime-linux|com\.apple\.virtualization\.thread\.cpu-' \
      "$profile" "$OUT/${prefix}-processes.xml" || {
      echo "Apple/VZ runtime samples missing from $trace" >&2
      return 1
    }
  fi
}

stop_trace() {
  local trace_pid="$1"
  kill -INT "$trace_pid" >/dev/null 2>&1 || true
  set +e
  wait "$trace_pid"
  local status=$?
  set -e
  case "$status" in
    0|130) ;;
    *) echo "xctrace exited with status $status" >&2; return "$status";;
  esac
}

record_case() {
  local run_name="$1"
  local label="$2"
  local runtime="$3"
  local prefix="$run_name-$label"
  local id="$PREFIX-$prefix"
  local trace="$OUT/${prefix}.trace"
  local notification="com.checkpt.container-runtime-krun.cpu.$$.${prefix}.started"

  create_case "$id" "$runtime" "$prefix"

  notifyutil -q -1 "$notification" >"$OUT/${prefix}-xctrace-notify.txt" 2>&1 &
  NOTIFY_PID=$!
  xcrun xctrace record \
    --template "CPU Profiler" \
    --all-processes \
    --time-limit "$TRACE_MAX_DURATION" \
    --output "$trace" \
    --run-name "$prefix" \
    --notify-tracing-started "$notification" \
    >"$OUT/${prefix}-xctrace-record.txt" 2>&1 &
  TRACE_PID=$!

  python3 - "$NOTIFY_PID" "$TRACE_PID" <<'PY_TRACE'
import os
import sys
import time

notify_pid, trace_pid = map(int, sys.argv[1:])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        os.kill(notify_pid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    try:
        os.kill(trace_pid, 0)
    except ProcessLookupError:
        raise SystemExit("xctrace exited before recording started")
    time.sleep(0.05)
raise SystemExit("timed out waiting for xctrace to start")
PY_TRACE
  wait "$NOTIFY_PID"
  NOTIFY_PID=""
  record_event "$run_name" "$label" trace_started

  record_event "$run_name" "$label" start_begin
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container start "$id" >"$OUT/${prefix}-start.txt" 2>&1
  record_event "$run_name" "$label" start_complete
  sleep "$POST_START_DELAY_SECONDS"
  record_event "$run_name" "$label" trace_stop

  stop_trace "$TRACE_PID"
  TRACE_PID=""
  finish_case "$id" "$prefix"
  export_profile "$trace" "$prefix" "$runtime"
}

printf 'run\tcase\tevent\twall_time_ns\tmonotonic_ns\n' >"$OUT/timeline.tsv"
{
  echo "timestamp=$STAMP"
  echo "runtime_a=$RUNTIME_A"
  echo "runtime_b=$RUNTIME_B"
  echo "image=$IMAGE"
  echo "trace_template=CPU Profiler"
  echo "trace_max_duration=$TRACE_MAX_DURATION"
  echo "post_start_delay_seconds=$POST_START_DELAY_SECONDS"
  echo "app_root=$APP_ROOT"
  echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
  xcodebuild -version 2>/dev/null || true
} >"$OUT/environment.txt"

xcrun xctrace list templates >"$OUT/xctrace-templates.txt" 2>&1
grep -Fq "CPU Profiler" "$OUT/xctrace-templates.txt" || {
  echo "CPU Profiler template is unavailable" >&2
  exit 1
}

# Each runtime gets two independent traces. Reversing order limits time drift
# without keeping one VM alive while the other runtime is measured.
record_case "ab" "a" "$RUNTIME_A"
record_case "ab" "b" "$RUNTIME_B"
record_case "ba" "b" "$RUNTIME_B"
record_case "ba" "a" "$RUNTIME_A"

tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
printf '%s\n' "$ARCHIVE"
