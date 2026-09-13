#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"
ITERATIONS=12
COMMAND_TIMEOUT_SECONDS=180
PREREQUISITE_TIMEOUT_SECONDS=600
CLEANUP_TIMEOUT_SECONDS=30

usage() {
  cat <<'USAGE'
Usage: scripts/validate_copy.sh [options]

Validate host/container file and directory copy through a selected runtime.

Options:
  --install          Build/install the checkout and restart Apple Container first.
  --runtime RUNTIME  Runtime to validate (default: container-runtime-krun).
  --image IMAGE      Test image (default: alpine:3.20).
  --iterations N     Repeated copy round trips (default: 12).
  --command-timeout N
                     Liveness deadline per runtime command in seconds (default: 180).
  --result-root DIR  Output directory (default: validation-results).
  -h, --help         Show this help.
USAGE
}

while (($#)); do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --runtime)
      RUNTIME="${2:?missing value for --runtime}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --iterations)
      ITERATIONS="${2:?missing value for --iterations}"
      shift 2
      ;;
    --command-timeout)
      COMMAND_TIMEOUT_SECONDS="${2:?missing value for --command-timeout}"
      shift 2
      ;;
    --result-root)
      RESULT_ROOT="${2:?missing value for --result-root}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || ((ITERATIONS < 1)); then
  echo "--iterations must be a positive integer" >&2
  exit 2
fi
if ! [[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || ((COMMAND_TIMEOUT_SECONDS < 1)); then
  echo "--command-timeout must be a positive integer" >&2
  exit 2
fi

for command in container python3 git make ps tar cmp; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-copy-${STAMP}-$$"
CONTAINER_ID="$PREFIX-main"
RESULT_DIR="$RESULT_ROOT/copy-${STAMP}-$$"
RUNTIME_SLUG="${RUNTIME//\//-}"
ARCHIVE="$RESULT_ROOT/${RUNTIME_SLUG}-copy-${STAMP}-$$.tar.gz"
FIXTURES="$RESULT_DIR/fixtures"
OUTPUTS="$RESULT_DIR/outputs"
mkdir -p "$FIXTURES/tree/sub" "$OUTPUTS"

FAILURES=0
CONTAINER_CREATED=0

log() {
  printf '%s\n' "$*" | tee -a "$RESULT_DIR/progress.txt"
}

pass() {
  printf 'PASS: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt"
}

fail() {
  printf 'FAIL: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt" >&2
  FAILURES=$((FAILURES + 1))
}

run_bounded() {
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

run_capture_with_timeout() {
  local name="$1"
  local timeout_seconds="$2"
  local status
  shift 2
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    run_bounded "$timeout_seconds" "$@"
    status=$?
    printf '\nexit_status=%d\n' "$status"
  } >"$RESULT_DIR/$name.txt" 2>&1
  return "$status"
}

run_capture() {
  local name="$1"
  shift
  run_capture_with_timeout "$name" "$COMMAND_TIMEOUT_SECONDS" "$@"
}

expect_success() {
  local name="$1"
  local status
  shift
  if run_capture "$name" "$@"; then
    pass "$name"
  else
    status=$?
    fail "$name"
    if ((status == 124)); then
      abort_timeout "$name"
    fi
  fi
}


expect_success_with_timeout() {
  local name="$1"
  local timeout_seconds="$2"
  local status
  shift 2
  if run_capture_with_timeout "$name" "$timeout_seconds" "$@"; then
    pass "$name"
  else
    status=$?
    fail "$name"
    if ((status == 124)); then
      abort_timeout "$name"
    fi
  fi
}

expect_failure() {
  local name="$1"
  local status
  shift
  if run_capture "$name" "$@"; then
    fail "$name unexpectedly succeeded"
  else
    status=$?
    if ((status == 124)); then
      fail "$name timed out"
      abort_timeout "$name"
    fi
    pass "$name rejected"
  fi
}

expect_failure_matching() {
  local name="$1"
  local pattern="$2"
  local status
  shift 2
  if run_capture "$name" "$@"; then
    fail "$name unexpectedly succeeded"
    return
  else
    status=$?
  fi
  if ((status == 124)); then
    fail "$name timed out"
    abort_timeout "$name"
  elif grep -Fq -- "$pattern" "$RESULT_DIR/$name.txt"; then
    pass "$name rejected as expected"
  else
    fail "$name failed for an unexpected reason"
  fi
}

container_state() {
  container inspect "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)
    print(items[0]["status"]["state"])
except Exception:
    raise SystemExit(1)
' 2>/dev/null
}

wait_for_state() {
  local id="$1"
  local expected="$2"
  local timeout_seconds="${3:-15}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ "$(container_state "$id" || true)" == "$expected" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_runtime_cleanup() {
  local id="$1"
  local timeout_seconds="${2:-15}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ "$RUNTIME" == "container-runtime-krun" ]]; then
      if ! /bin/ps -axo command= | grep -F -- "$id" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper'; then
        return 0
      fi
    elif ! /bin/ps -axo command= | grep -F -- "$id" | grep -Fq -- "$RUNTIME"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

list_krun_runtime_dirs() {
  local directory
  for directory in /tmp/ckr-*; do
    [[ -d "$directory" ]] || continue
    printf '%s\n' "$directory"
  done | sort
}

capture_diagnostics() {
  local label="$1"
  local status_file="$RESULT_DIR/system-status-$label.json"
  local app_root log_root bundle_root path

  run_bounded 15 container inspect "$CONTAINER_ID" >"$RESULT_DIR/container-inspect-$label.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= >"$RESULT_DIR/processes-$label.txt" 2>&1 || true
  run_bounded 15 container system status --format json >"$status_file" 2>&1 || true
  run_bounded 15 container system logs --debug --last 10m >"$RESULT_DIR/system-logs-$label.txt" 2>&1 || true

  app_root="$(python3 - "$status_file" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('')
else:
    print(data.get('appRoot') or (data.get('paths') or {}).get('appRoot') or '')
PY
)"
  log_root="$(python3 - "$status_file" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('')
else:
    print(data.get('logRoot') or (data.get('paths') or {}).get('logRoot') or '')
PY
)"

  if [[ -n "$app_root" ]]; then
    bundle_root="$app_root/containers/$CONTAINER_ID"
    for path in "$bundle_root"/krun-vmm.log "$bundle_root"/vminitd.log \
      "$bundle_root"/container.log "$bundle_root"/krun-vmm.json; do
      [[ -r "$path" ]] || continue
      cp "$path" "$RESULT_DIR/$label-$(basename "$path")"
    done
  fi
  if [[ -n "$log_root" && -r "$log_root/$RUNTIME-$CONTAINER_ID.log" ]]; then
    cp "$log_root/$RUNTIME-$CONTAINER_ID.log" "$RESULT_DIR/runtime-plugin-$label.log"
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -U >"$RESULT_DIR/unix-sockets-$label.txt" 2>&1 || true
  fi
}

abort_timeout() {
  local name="$1"
  log "$name timed out; collecting live copy diagnostics"
  capture_diagnostics "$name-timeout"
  finish_validation
  exit 1
}

finish_validation() {
  run_bounded 15 container list --all >"$RESULT_DIR/container-list-final.txt" 2>&1 || true
  if [[ "$RUNTIME" == "container-runtime-krun" ]]; then
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
      | grep -v grep >"$RESULT_DIR/runtime-processes-final.txt" || true
  else
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -F -- "$RUNTIME" \
      | grep -v grep >"$RESULT_DIR/runtime-processes-final.txt" || true
  fi

  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "iterations=$ITERATIONS"
    echo "command_timeout_seconds=$COMMAND_TIMEOUT_SECONDS"
    echo "prerequisite_timeout_seconds=$PREREQUISITE_TIMEOUT_SECONDS"
    echo "failures=$FAILURES"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  } >"$RESULT_DIR/SUMMARY.txt"

  mkdir -p "$RESULT_ROOT"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
  printf 'archive=%s\n' "$ARCHIVE" | tee -a "$RESULT_DIR/progress.txt"
}

cleanup() {
  set +e
  if ((CONTAINER_CREATED)); then
    run_bounded "$CLEANUP_TIMEOUT_SECONDS" container delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
}
interrupt() {
  local status="$1"
  trap - EXIT INT TERM
  log "interrupted; collecting diagnostics and preserving partial results"
  capture_diagnostics interrupt
  finish_validation
  cleanup
  exit "$status"
}
trap cleanup EXIT
trap 'interrupt 130' INT
trap 'interrupt 143' TERM

printf 'host-file-payload\n' >"$FIXTURES/host-file.txt"
printf 'tree-root\n' >"$FIXTURES/tree/root.txt"
printf 'tree-child\n' >"$FIXTURES/tree/sub/child.txt"
python3 - "$FIXTURES/blob.bin" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
block = bytes(range(256))
path.write_bytes(block * 4096)
PY

if [[ "$RUNTIME" == "container-runtime-krun" ]]; then
  list_krun_runtime_dirs >"$RESULT_DIR/initial-runtime-dirs.txt"
fi

if ((INSTALL)); then
  log "building and installing current checkout"
  expect_success_with_timeout make_doctor "$PREREQUISITE_TIMEOUT_SECONDS" make doctor
  expect_success_with_timeout make_check "$PREREQUISITE_TIMEOUT_SECONDS" make check
  expect_success_with_timeout make_test "$PREREQUISITE_TIMEOUT_SECONDS" make test
  expect_success_with_timeout make_install "$PREREQUISITE_TIMEOUT_SECONDS" make install
  if ((FAILURES > 0)); then
    log "build/install prerequisites failed; skipping runtime copy checks"
    finish_validation
    exit 1
  fi

  expect_success system_stop container system stop
  expect_success system_start container system start
  if ((FAILURES > 0)); then
    log "Apple Container restart failed; skipping runtime copy checks"
    finish_validation
    exit 1
  fi
fi

expect_success git_status git status --short
expect_success container_version container --version

container delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true
if expect_success run_container container run -d --name "$CONTAINER_ID" --runtime "$RUNTIME" --network none \
  "$IMAGE" sh -c 'mkdir -p /copy/existing; printf "guest-seed\n" >/copy/guest-seed.txt; sleep 300'; then
  CONTAINER_CREATED=1
fi

if wait_for_state "$CONTAINER_ID" running 20; then
  pass "container reached running state"
else
  fail "container did not reach running state"
fi

# Host -> guest: regular file, exact destination.
expect_success copy_in_file container copy "$FIXTURES/host-file.txt" "$CONTAINER_ID:/copy/in.txt"
if [[ "$(container exec "$CONTAINER_ID" cat /copy/in.txt 2>/dev/null || true)" == "host-file-payload" ]]; then
  pass "copyIn regular file content"
else
  fail "copyIn regular file content"
fi

# Existing guest directory must receive the host basename, matching Apple Container semantics.
expect_success copy_in_existing_dir container copy "$FIXTURES/host-file.txt" "$CONTAINER_ID:/copy/existing"
existing_dir_content="$(
  container exec "$CONTAINER_ID" cat /copy/existing/host-file.txt 2>/dev/null || true
)"
if [[ "$existing_dir_content" == "host-file-payload" ]]; then
  pass "copyIn existing-directory destination semantics"
else
  fail "copyIn existing-directory destination semantics"
fi

# A trailing slash denotes an existing directory requirement for file copies.
expect_failure_matching copy_in_missing_dir "destination directory does not exist" \
  container copy "$FIXTURES/host-file.txt" "$CONTAINER_ID:/copy/missing/"

# Host -> guest: directory archive transfer.
expect_success copy_in_directory container copy "$FIXTURES/tree" "$CONTAINER_ID:/copy/tree"
if [[ "$(container exec "$CONTAINER_ID" cat /copy/tree/root.txt 2>/dev/null || true)" == "tree-root" ]] \
  && [[ "$(container exec "$CONTAINER_ID" cat /copy/tree/sub/child.txt 2>/dev/null || true)" == "tree-child" ]]; then
  pass "copyIn directory tree"
else
  fail "copyIn directory tree"
fi

# Guest -> host: regular file.
expect_success copy_out_file container copy "$CONTAINER_ID:/copy/guest-seed.txt" "$OUTPUTS/guest-seed.txt"
if [[ "$(cat "$OUTPUTS/guest-seed.txt" 2>/dev/null || true)" == "guest-seed" ]]; then
  pass "copyOut regular file content"
else
  fail "copyOut regular file content"
fi

# Guest -> host: directory archive transfer.
expect_success copy_out_directory container copy "$CONTAINER_ID:/copy/tree" "$OUTPUTS/tree"
if [[ "$(cat "$OUTPUTS/tree/root.txt" 2>/dev/null || true)" == "tree-root" ]] \
  && [[ "$(cat "$OUTPUTS/tree/sub/child.txt" 2>/dev/null || true)" == "tree-child" ]]; then
  pass "copyOut directory tree"
else
  fail "copyOut directory tree"
fi

# Exercise transfer-slot reuse beyond one full copy-port-pool cycle.
for ((i = 1; i <= ITERATIONS; i++)); do
  guest_path="/copy/blob-$i.bin"
  host_path="$OUTPUTS/blob-$i.bin"
  in_status=0
  out_status=0
  run_capture "roundtrip-$i-in" container copy "$FIXTURES/blob.bin" "$CONTAINER_ID:$guest_path" || in_status=$?
  if ((in_status == 124)); then
    fail "copy round trip $i input timed out"
    abort_timeout "roundtrip-$i-in"
  fi
  if ((in_status == 0)); then
    run_capture "roundtrip-$i-out" container copy "$CONTAINER_ID:$guest_path" "$host_path" || out_status=$?
    if ((out_status == 124)); then
      fail "copy round trip $i output timed out"
      abort_timeout "roundtrip-$i-out"
    fi
  fi
  if ((in_status == 0 && out_status == 0)) && cmp -s "$FIXTURES/blob.bin" "$host_path"; then
    pass "copy round trip $i"
  else
    fail "copy round trip $i"
  fi
done

# Several simultaneous transfers verify copy slots are independent of one another.
CONCURRENT_FAILURES=0
PIDS=()
for i in 1 2 3 4; do
  (
    run_bounded "$COMMAND_TIMEOUT_SECONDS" container copy "$FIXTURES/blob.bin" "$CONTAINER_ID:/copy/concurrent-$i.bin" \
      >"$RESULT_DIR/concurrent-$i.txt" 2>&1
  ) &
  PIDS+=("$!")
done
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    CONCURRENT_FAILURES=$((CONCURRENT_FAILURES + 1))
  fi
done
if ((CONCURRENT_FAILURES == 0)); then
  pass "four concurrent copyIn operations"
else
  fail "$CONCURRENT_FAILURES concurrent copyIn operations failed"
fi

for i in 1 2 3 4; do
  if ! container exec "$CONTAINER_ID" test -s "/copy/concurrent-$i.bin" >/dev/null 2>&1; then
    fail "concurrent copyIn output $i missing"
  fi
done

# Runtime errors must not poison the container or leak the transfer slot.
expect_failure_matching copy_out_missing "stat: path not found" \
  container copy "$CONTAINER_ID:/copy/does-not-exist" "$OUTPUTS/missing"
if [[ "$(container exec "$CONTAINER_ID" sh -c 'printf copy-health-ok' 2>/dev/null || true)" == "copy-health-ok" ]]; then
  pass "container usable after rejected copy"
else
  fail "container unusable after rejected copy"
fi
expect_success copy_after_failure container copy "$FIXTURES/host-file.txt" "$CONTAINER_ID:/copy/after-failure.txt"

expect_success stop_container container stop "$CONTAINER_ID"
expect_success delete_container container delete "$CONTAINER_ID"
CONTAINER_CREATED=0

if wait_for_runtime_cleanup "$CONTAINER_ID" 15; then
  pass "runtime and VMM helpers cleaned up"
else
  fail "runtime or VMM helper remained after delete"
fi

if [[ "$RUNTIME" == "container-runtime-krun" ]]; then
  list_krun_runtime_dirs >"$RESULT_DIR/final-runtime-dirs.txt"
  comm -13 "$RESULT_DIR/initial-runtime-dirs.txt" "$RESULT_DIR/final-runtime-dirs.txt" \
    >"$RESULT_DIR/new-runtime-dirs.txt"
  if [[ ! -s "$RESULT_DIR/new-runtime-dirs.txt" ]]; then
    pass "copy validation left no new krun socket directories"
  else
    fail "copy validation left new krun socket directories"
  fi
fi

finish_validation

if ((FAILURES > 0)); then
  exit 1
fi
