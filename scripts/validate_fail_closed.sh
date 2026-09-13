#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"
COMMAND_TIMEOUT_SECONDS=60
DIAL_HELPER=""

usage() {
  cat <<'USAGE'
Usage: scripts/validate_fail_closed.sh [options]

Validate the remaining fail-closed feature boundaries through the real Apple
Container control plane. Configuration-time feature gates must reject before
VM startup. Runtime-only routes are exercised against one live krun container.

Options:
  --install          Build/install the checkout and restart Apple Container.
  --image IMAGE      Test image (default: alpine:3.20).
  --result-root DIR  Output directory (default: validation-results).
  --timeout SECONDS  Per-operation timeout (default: 60).
  --dial-helper PATH  Optional executable that calls ContainerAPIClient.dial
                      as: HELPER CONTAINER_ID PORT. When omitted, dial is
                      reported as SKIP because Container 1.3.1 has no
                      general-purpose dial CLI command.
  -h, --help         Show this help.

USAGE
}

while (($#)); do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --result-root)
      RESULT_ROOT="${2:?missing value for --result-root}"
      shift 2
      ;;
    --timeout)
      COMMAND_TIMEOUT_SECONDS="${2:?missing value for --timeout}"
      shift 2
      ;;
    --dial-helper)
      DIAL_HELPER="${2:?missing value for --dial-helper}"
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

if ! [[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || ((COMMAND_TIMEOUT_SECONDS < 1)); then
  echo "--timeout must be a positive integer" >&2
  exit 2
fi

for command in container python3 git mise ps; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-gate8-${STAMP}-$$"
RESULT_DIR="$RESULT_ROOT/gate8-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-gate8-${STAMP}-$$.tar.gz"
ROUTE_ID="$PREFIX-routes"
INITIAL_SOCKETS="$RESULT_DIR/initial-sockets.txt"
HOST_MOUNT_DIR="$RESULT_DIR/host-mount"
mkdir -p "$RESULT_DIR" "$HOST_MOUNT_DIR"

FAILURES=0
PASSES=0
SKIPS=0
declare -a CONFIG_IDS=()
declare -a CLEANUP_IDS=()

log() {
  printf '%s\n' "$*" | tee -a "$RESULT_DIR/progress.txt"
}

pass() {
  PASSES=$((PASSES + 1))
  printf 'PASS: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt" >&2
}

skip() {
  SKIPS=$((SKIPS + 1))
  printf 'SKIP: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt"
}

run_capture() {
  local name="$1"
  local status
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    status=$?
    printf '\nexit_status=%d\n' "$status"
  } >"$RESULT_DIR/$name.txt" 2>&1
  return "$status"
}

# Execute a command with a hard wall-clock limit without depending on GNU timeout.
# The output file includes the exact argv, elapsed time, timeout state, and status.
run_capture_timeout() {
  local name="$1"
  local timeout_seconds="$2"
  shift 2
  python3 - "$RESULT_DIR/$name.txt" "$timeout_seconds" "$@" <<'PY'
import shlex
import subprocess
import sys
import time

output_path = sys.argv[1]
timeout = float(sys.argv[2])
command = sys.argv[3:]
start = time.monotonic()
status = 125
timed_out = False

with open(output_path, "w", encoding="utf-8", errors="replace") as output:
    output.write("$ " + shlex.join(command) + "\n")
    output.flush()
    try:
        completed = subprocess.run(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        status = completed.returncode
    except subprocess.TimeoutExpired:
        timed_out = True
        status = 124
        output.write(f"\ncommand timed out after {timeout:g} seconds\n")
    except Exception as exc:
        status = 125
        output.write(f"\ncommand execution failed: {exc!r}\n")

    elapsed_ms = int((time.monotonic() - start) * 1000)
    output.write(f"\nelapsed_ms={elapsed_ms}\n")
    output.write(f"timed_out={1 if timed_out else 0}\n")
    output.write(f"exit_status={status}\n")

raise SystemExit(status if 0 <= status <= 255 else 125)
PY
}

expect_success() {
  local name="$1"
  shift
  if run_capture "$name" "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_unsupported() {
  local name="$1"
  local expected="$2"
  shift 2

  run_capture_timeout "$name" "$COMMAND_TIMEOUT_SECONDS" "$@"
  local status=$?
  local output="$RESULT_DIR/$name.txt"

  if ((status == 0)); then
    fail "$name unexpectedly succeeded"
    return 1
  fi
  if ((status == 124)); then
    fail "$name timed out instead of failing closed"
    return 1
  fi
  if ((status == 125)); then
    fail "$name could not be executed"
    return 1
  fi

  if grep -Fq -- "$expected" "$output"; then
    pass "$name rejected with expected unsupported boundary"
    return 0
  fi

  fail "$name failed, but did not report expected boundary: $expected"
  return 1
}

absolute_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

free_tcp_port() {
  python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

capture_runtime_state() {
  local output="$1"
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo '--- processes ---'
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -E 'container-runtime-krun|container-krun-vmm-helper|vmnet-helper' \
      | grep -v grep || true
    echo '--- krun network sockets ---'
    list_network_sockets
    echo '--- gate8 containers ---'
    container list --all 2>/dev/null | grep -F "$PREFIX" || true
  } >"$output"
}

list_network_sockets() {
  local directory socket
  for directory in /tmp/container-krun-net-*; do
    [[ -d "$directory" ]] || continue
    for socket in "$directory"/*.sock; do
      [[ -S "$socket" ]] || continue
      echo "$socket"
    done
  done | sort
}

wait_for_runtime_cleanup() {
  local id="$1"
  local timeout_seconds="${2:-10}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if ! /bin/ps -axo command= | grep -F -- "$id" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper|vmnet-helper'; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

container_exists() {
  container inspect "$1" >/dev/null 2>&1
}

cleanup_container() {
  local id="$1"
  container delete --force "$id" >/dev/null 2>&1 || true
}

cleanup() {
  local id
  for id in "${CLEANUP_IDS[@]:-}"; do
    [[ -n "$id" ]] || continue
    cleanup_container "$id"
  done
}

on_signal() {
  local status="$1"
  trap - EXIT INT TERM
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

record_config_id() {
  CONFIG_IDS+=("$1")
  CLEANUP_IDS+=("$1")
}

run_feature_gate_case() {
  local suffix="$1"
  local expected_feature="$2"
  shift 2
  local id="$PREFIX-$suffix"
  local expected="container-runtime-krun does not support $expected_feature"

  record_config_id "$id"
  expect_unsupported "feature-$suffix" "$expected" \
    container run --rm --name "$id" --runtime "$RUNTIME" "$@"
  cleanup_container "$id"
}

check_config_rejections_did_not_start_vms() {
  local logs="$RESULT_DIR/system-logs-container.txt"
  local id id_logs

  if ! container system logs --debug --last 15m >"$logs" 2>&1; then
    skip "system logs unavailable; could not independently verify pre-VM rejection traces"
    return 0
  fi

  for id in "${CONFIG_IDS[@]}"; do
    id_logs="$RESULT_DIR/pre-vm-${id#${PREFIX}-}.txt"
    grep -F -- "$id" "$logs" >"$id_logs" 2>/dev/null || true

    if grep -Eq '\[event=(network allocation start|vmnet-helper launch|libkrun helper launch|guest setup start)' "$id_logs"; then
      fail "$id started VM/network resources before rejecting unsupported configuration"
    else
      pass "$id rejected before VM/network startup"
    fi
  done
}

check_no_new_sockets() {
  local name="$1"
  list_network_sockets >"$RESULT_DIR/$name-sockets.txt"
  comm -13 "$INITIAL_SOCKETS" "$RESULT_DIR/$name-sockets.txt" >"$RESULT_DIR/$name-new-sockets.txt"
  if [[ ! -s "$RESULT_DIR/$name-new-sockets.txt" ]]; then
    pass "$name left no new krun Unix sockets"
  else
    fail "$name left new krun Unix sockets"
  fi
}

log "Gate 8 fail-closed validation"
log "runtime=$RUNTIME image=$IMAGE"

{
  echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "git_branch=$(git branch --show-current 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "swift_version=$(swift --version 2>&1 | head -1 || true)"
} >"$RESULT_DIR/environment.txt"

git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true
capture_runtime_state "$RESULT_DIR/runtime-state-initial.txt"
list_network_sockets >"$INITIAL_SOCKETS"

expect_success mise_doctor mise run doctor
expect_success mise_check mise run check
expect_success mise_test mise run test

if ((INSTALL)); then
  expect_success mise_install mise run install
  expect_success system_stop container system stop
  expect_success system_start container system start
fi

HOST_MOUNT_DIR_ABS="$(absolute_path "$HOST_MOUNT_DIR")"
NO_NETWORK_PORT="$(free_tcp_port)"

# Configuration-time feature gates. Every command must fail with the runtime's
# explicit unsupported message. The post-run system-log check additionally
# verifies that no vmnet/libkrun/guest setup lifecycle event was reached.
run_feature_gate_case \
  host-mount \
  "host, block, and virtiofs mounts" \
  --network none \
  --mount "type=bind,source=${HOST_MOUNT_DIR_ABS},target=/mnt/gate8" \
  "$IMAGE" true

run_feature_gate_case \
  rosetta \
  "Rosetta; use Apple's official runtime for x86_64 emulation" \
  --network none \
  --rosetta \
  "$IMAGE" true

run_feature_gate_case \
  nested-virtualization \
  "nested virtualization" \
  --network none \
  --virtualization \
  "$IMAGE" true

# This boundary is implemented by the same feature gate even though the Gate 8
# checklist primarily calls out the remaining feature families above.
run_feature_gate_case \
  publish-without-network \
  "published TCP/UDP ports without a network attachment" \
  --network none \
  --publish "127.0.0.1:${NO_NETWORK_PORT}:80/tcp" \
  "$IMAGE" true

check_config_rejections_did_not_start_vms
capture_runtime_state "$RESULT_DIR/runtime-state-after-feature-gates.txt"
check_no_new_sockets feature_gates

# Runtime-route gates need a live, otherwise-supported container so the API
# server actually forwards each request to container-runtime-krun.
CLEANUP_IDS+=("$ROUTE_ID")
if run_capture_timeout route-container-start "$COMMAND_TIMEOUT_SECONDS" \
  container run -d \
    --name "$ROUTE_ID" \
    --runtime "$RUNTIME" \
    --network none \
    "$IMAGE" sh -c 'while :; do sleep 1; done'; then
  pass "runtime-route container started"
else
  fail "runtime-route container started"
fi

if run_capture_timeout route-container-live "$COMMAND_TIMEOUT_SECONDS" \
  container exec "$ROUTE_ID" true; then
  pass "runtime-route container is usable before unsupported-route probes"
else
  fail "runtime-route container is usable before unsupported-route probes"
fi
container inspect "$ROUTE_ID" >"$RESULT_DIR/route-container-inspect.txt" 2>&1 || true
capture_runtime_state "$RESULT_DIR/runtime-state-routes-live.txt"

# Container 1.3.1 has no general-purpose CLI command for ContainerClient.dial.
# An externally supplied validation helper may exercise it without forcing this
# script to compile a second Apple Container dependency graph.
if [[ -n "$DIAL_HELPER" ]]; then
  if [[ -x "$DIAL_HELPER" ]]; then
    expect_unsupported \
      route-dial \
      "container-runtime-krun does not support runtime route dial" \
      "$DIAL_HELPER" "$ROUTE_ID" 12345
  else
    fail "dial helper is not executable: $DIAL_HELPER"
  fi
else
  skip "route-dial not behaviorally reachable: Container 1.3.1 has no general-purpose dial CLI command"
fi

# The route probes must fail without damaging the live container.
if run_capture_timeout route-container-still-live "$COMMAND_TIMEOUT_SECONDS" \
  container exec "$ROUTE_ID" sh -c 'printf gate8-route-container-ok'; then
  if grep -Fq 'gate8-route-container-ok' "$RESULT_DIR/route-container-still-live.txt"; then
    pass "unsupported runtime routes leave the container usable"
  else
    fail "unsupported runtime routes leave the container usable"
  fi
else
  fail "unsupported runtime routes leave the container usable"
fi

if run_capture_timeout route-container-stop "$COMMAND_TIMEOUT_SECONDS" \
  container stop "$ROUTE_ID"; then
  pass "runtime-route container stopped"
else
  fail "runtime-route container stopped"
fi
if run_capture_timeout route-container-delete "$COMMAND_TIMEOUT_SECONDS" \
  container delete "$ROUTE_ID"; then
  pass "runtime-route container deleted"
else
  fail "runtime-route container deleted"
fi

if wait_for_runtime_cleanup "$ROUTE_ID" 10; then
  pass "runtime-route helpers cleaned up"
else
  fail "runtime-route helpers cleaned up"
fi

capture_runtime_state "$RESULT_DIR/runtime-state-final.txt"
check_no_new_sockets final_cleanup

if container list --all >"$RESULT_DIR/container-list-final.txt" 2>&1; then
  if grep -Fq "$PREFIX" "$RESULT_DIR/container-list-final.txt"; then
    fail "Gate 8 test containers were removed"
  else
    pass "Gate 8 test containers were removed"
  fi
else
  fail "final container list was readable"
fi

# Preserve the relevant runtime/control-plane messages for review.
container system logs --debug --last 15m >"$RESULT_DIR/system-logs-final.txt" 2>&1 || true
grep -E "$PREFIX|container-runtime-krun does not support" \
  "$RESULT_DIR/system-logs-final.txt" >"$RESULT_DIR/system-logs-relevant.txt" 2>/dev/null || true

{
  echo "runtime=$RUNTIME"
  echo "image=$IMAGE"
  echo "feature_gate_cases=${#CONFIG_IDS[@]}"
  echo "runtime_route_cases=1"
  echo "passes=$PASSES"
  echo "skips=$SKIPS"
  echo "failures=$FAILURES"
  if [[ -n "$DIAL_HELPER" ]]; then
    echo "dial_validation=external helper: $DIAL_HELPER"
  else
    echo "dial_validation=skipped: no public Container 1.3.1 dial CLI"
  fi
} >"$RESULT_DIR/SUMMARY.txt"

mkdir -p "$RESULT_ROOT"
tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
log "archive: $ARCHIVE"

trap - EXIT INT TERM

if ((FAILURES > 0)); then
  exit 1
fi
