#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="container-runtime-krun"
NETWORK="default"
IMAGE="alpine:3.20"
INSTALL=0
REQUIRE_PTY_STARTUP=0
PTY_STARTUP_STATUS="NOT_RUN"
CYCLES=5
MEMORY_OBSERVE_SECONDS=120
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_runtime_regression.sh [options]

Validate the v0.1 runtime lifecycle and memory-reclamation contracts with the
v0.2 allocationOnly network enabled.

Options:
  --install                   Build/install the current checkout and restart Apple Container.
  --network NAME              Apple allocationOnly network to use (default: Apple default network).
  --image IMAGE               Test image (default: alpine:3.20).
  --cycles N                  Repeated create/delete cycles (default: 5).
  --memory-observe-seconds N  Host observation after releasing 1 GiB (default: 120).
  --require-pty-startup        Also gate on the separate CLI startup-resize diagnostic.
  --result-root DIR           Output directory (default: validation-results).
  -h, --help                  Show this help.
USAGE
}

while (($#)); do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --network)
      NETWORK="${2:?missing value for --network}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --cycles)
      CYCLES="${2:?missing value for --cycles}"
      shift 2
      ;;
    --memory-observe-seconds)
      MEMORY_OBSERVE_SECONDS="${2:?missing value for --memory-observe-seconds}"
      shift 2
      ;;
    --require-pty-startup)
      REQUIRE_PTY_STARTUP=1
      shift
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

if ! [[ "$CYCLES" =~ ^[0-9]+$ ]] || ((CYCLES < 1)); then
  echo "--cycles must be a positive integer" >&2
  exit 2
fi
if ! [[ "$MEMORY_OBSERVE_SECONDS" =~ ^[0-9]+$ ]] || ((MEMORY_OBSERVE_SECONDS < 0)); then
  echo "--memory-observe-seconds must be a non-negative integer" >&2
  exit 2
fi

for command in container python3 git mise ps vm_stat sysctl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-reg-${STAMP}-$$"
RESULT_DIR="$RESULT_ROOT/runtime-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-regression-${STAMP}-$$.tar.gz"
mkdir -p "$RESULT_DIR"

START_LOCAL="$(date '+%Y-%m-%d %H:%M:%S')"
FAILURES=0
WARNINGS=0
declare -a CONTAINERS=()

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

warn() {
  printf 'WARN: %s\n' "$*" | tee -a "$RESULT_DIR/results.txt" >&2
  WARNINGS=$((WARNINGS + 1))
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

run_shell_capture() {
  local name="$1"
  local status
  shift
  {
    printf '$ %s\n' "$*"
    /bin/bash -c "$*"
    status=$?
    printf '\nexit_status=%d\n' "$status"
  } >"$RESULT_DIR/$name.txt" 2>&1
  return "$status"
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

expect_status() {
  local expected="$1"
  local name="$2"
  shift 2
  run_capture "$name" "$@"
  local status=$?
  if ((status == expected)); then
    pass "$name exited $expected"
  else
    fail "$name exited $status, expected $expected"
  fi
}

register_container() {
  CONTAINERS+=("$1")
}

container_state() {
  local id="$1"
  container inspect "$id" 2>/dev/null | python3 -c '
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
  local timeout_seconds="${3:-10}"
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
  local timeout_seconds="${2:-10}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if ! /bin/ps -axo command= | grep -F -- "$id" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper'; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}


copy_if_readable() {
  local source="$1"
  local destination="$2"
  if [[ -r "$source" ]]; then
    cp "$source" "$destination"
  fi
}

capture_runtime_state() {
  local output="$1"
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo '--- processes ---'
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -E 'container-runtime-krun|container-krun-vmm-helper|vmnet-helper' \
      | grep -v grep || true
    echo '--- krun network directories ---'
    local directory socket
    for directory in /tmp/container-krun-net-*; do
      [[ -d "$directory" ]] || continue
      for socket in "$directory"/*.sock; do
        [[ -S "$socket" ]] || continue
        echo "$socket"
      done
    done
  } >"$output"
}

cleanup() {
  set +e
  for id in "${CONTAINERS[@]}"; do
    container delete --force "$id" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

check_no_new_network_dirs() {
  local name="$1"
  capture_runtime_state "$RESULT_DIR/$name-state.txt"
  {
    local directory socket
    for directory in /tmp/container-krun-net-*; do
      [[ -d "$directory" ]] || continue
      for socket in "$directory"/*.sock; do
        [[ -S "$socket" ]] || continue
        echo "$socket"
      done
    done
  } | sort >"$RESULT_DIR/$name-sockets.txt"
  comm -13 "$RESULT_DIR/initial-sockets.txt" "$RESULT_DIR/$name-sockets.txt" \
    >"$RESULT_DIR/$name-new-sockets.txt"
  if [[ ! -s "$RESULT_DIR/$name-new-sockets.txt" ]]; then
    pass "$name left no new krun Unix sockets"
  else
    fail "$name left new krun Unix sockets"
  fi
}

capture_host_memory() {
  local phase="$1"
  local index="$2"
  local id="$3"
  local output="$RESULT_DIR/memory-host.txt"
  local pid
  {
    printf '\n===== phase=%s sample=%s timestamp=%s =====\n' "$phase" "$index" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo '--- vm_stat ---'
    vm_stat
    echo '--- swap ---'
    sysctl vm.swapusage
    echo '--- runtime processes ---'
    /bin/ps -axo pid=,ppid=,rss=,vsz=,command= | grep -F -- "$id" | grep -v grep || true
    pid="$(/bin/ps -axo pid=,command= \
      | awk -v id="$id" 'index($0, "container-krun-vmm-helper") && index($0, id) {print $1; exit}')"
    if [[ -n "$pid" ]]; then
      echo "--- top pid=$pid ---"
      /usr/bin/top -l 1 -pid "$pid" -stats pid,command,mem || true
    fi
  } >>"$output" 2>&1
}

sample_host_memory_for() {
  local phase="$1"
  local seconds="$2"
  local id="$3"
  local index=0
  local deadline=$((SECONDS + seconds))
  log "memory observation: phase=$phase duration=${seconds}s (samples in memory-host.txt)"
  while :; do
    capture_host_memory "$phase" "$index" "$id"
    index=$((index + 1))
    ((SECONDS >= deadline)) && break
    sleep 5
  done
}

run_pty_resize_probe() {
  python3 "$SCRIPT_DIR/pty_resize_probe.py" "$@"
}

log "results: $RESULT_DIR"
{
  echo "timestamp_utc=$STAMP"
  echo "prefix=$PREFIX"
  echo "runtime=$RUNTIME"
  echo "network=$NETWORK"
  echo "image=$IMAGE"
  echo "cycles=$CYCLES"
  echo "memory_observe_seconds=$MEMORY_OBSERVE_SECONDS"
  echo "require_pty_startup=$REQUIRE_PTY_STARTUP"
  echo "started_local=$START_LOCAL"
} >"$RESULT_DIR/run.env"

git rev-parse HEAD >"$RESULT_DIR/git-head.txt" 2>&1 || true
git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true
container --version >"$RESULT_DIR/container-version.txt" 2>&1 || true
container system status --format json >"$RESULT_DIR/system-status.json" 2>&1 || true
APP_ROOT="$(python3 - "$RESULT_DIR/system-status.json" <<'PY'
import json
import sys

try:
    status = json.load(open(sys.argv[1], encoding="utf-8"))
    print(status.get("appRoot") or status.get("paths", {}).get("appRoot") or "")
except Exception:
    print("")
PY
)"
container network inspect "$NETWORK" >"$RESULT_DIR/network-inspect.txt" 2>&1 || {
  fail "network $NETWORK is not available"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
  exit 1
}

capture_runtime_state "$RESULT_DIR/runtime-state-initial.txt"
{
  for directory in /tmp/container-krun-net-*; do
    [[ -d "$directory" ]] || continue
    for socket in "$directory"/*.sock; do
      [[ -S "$socket" ]] || continue
      echo "$socket"
    done
  done
} | sort >"$RESULT_DIR/initial-sockets.txt"

expect_success mise_doctor mise run doctor
expect_success mise_check mise run check
expect_success mise_test mise run test

if ((INSTALL)); then
  expect_success mise_install mise run install
  expect_success system_stop container system stop
  expect_success system_start container system start
fi

# Capture the installed library, not just the version configured in mise.toml.
expect_success libkrun_provenance "$SCRIPT_DIR/capture_libkrun_provenance.sh" "$RESULT_DIR"
{
  source_dir="$SCRIPT_DIR/../.build-deps/libkrun"
  echo "observed_checkout=$source_dir"
  echo 'This checkout observation does not prove which source built the installed dylib.'
  if [[ -e "$source_dir/.git" ]]; then
    git -C "$source_dir" rev-parse HEAD
    git -C "$source_dir" status --short
    git -C "$source_dir" diff --stat HEAD
    for dylib in "$source_dir"/target/release/libkrun.*.dylib; do
      [[ -r "$dylib" ]] || continue
      shasum -a 256 "$dylib"
    done
  else
    echo 'local libkrun checkout unavailable'
  fi
} >"$RESULT_DIR/libkrun-checkout.txt" 2>&1

# Natural init exit and nonzero init exit.
NORMAL_ID="$PREFIX-init"
register_container "$NORMAL_ID"
expect_status 0 init_exit container run --name "$NORMAL_ID" --runtime "$RUNTIME" --network "$NETWORK" "$IMAGE" true
if wait_for_state "$NORMAL_ID" stopped 5; then
  pass "normal init exit reached stopped"
else
  fail "normal init exit did not reach stopped"
fi
expect_success init_delete container delete "$NORMAL_ID"
wait_for_runtime_cleanup "$NORMAL_ID" 10 || fail "normal init runtime cleanup"

NONZERO_ID="$PREFIX-init-nonzero"
register_container "$NONZERO_ID"
expect_status 23 init_nonzero container run --name "$NONZERO_ID" --runtime "$RUNTIME" --network "$NETWORK" "$IMAGE" sh -c 'exit 23'
if wait_for_state "$NONZERO_ID" stopped 5; then
  pass "nonzero init exit reached stopped"
else
  fail "nonzero init exit did not reach stopped"
fi
expect_success init_nonzero_delete container delete "$NONZERO_ID"
wait_for_runtime_cleanup "$NONZERO_ID" 10 || fail "nonzero init runtime cleanup"

# Long-lived container for exec, stdio, PTY, stats, and graceful stop.
LIFE_ID="$PREFIX-life"
register_container "$LIFE_ID"
expect_success lifecycle_run container run -d --name "$LIFE_ID" --runtime "$RUNTIME" --network "$NETWORK" \
  "$IMAGE" sh -c 'trap "exit 0" TERM; while :; do sleep 1; done'
if wait_for_state "$LIFE_ID" running 10; then
  pass "lifecycle container running"
else
  fail "lifecycle container did not reach running"
fi
capture_runtime_state "$RESULT_DIR/runtime-state-life-live.txt"

expect_success exec_attached container exec "$LIFE_ID" sh -c 'echo stdout-ok; echo stderr-ok >&2'
if grep -q 'stdout-ok' "$RESULT_DIR/exec_attached.txt" && grep -q 'stderr-ok' "$RESULT_DIR/exec_attached.txt"; then
  pass "attached exec stdout/stderr"
else
  fail "attached exec stdout/stderr"
fi

run_shell_capture exec_stdin "printf '%s\\n' stdin-ok | container exec -i '$LIFE_ID' sh -c 'read line; echo stdin=\"\$line\"'"
if grep -q 'stdin=stdin-ok' "$RESULT_DIR/exec_stdin.txt"; then
  pass "interactive stdin"
else
  fail "interactive stdin"
fi

expect_status 37 exec_nonzero container exec "$LIFE_ID" sh -c 'exit 37'

expect_success exec_detached container exec -d "$LIFE_ID" sh -c 'sleep 0.2; echo detached-ok >/tmp/detached-ok'
sleep 0.5
expect_success exec_detached_verify container exec "$LIFE_ID" cat /tmp/detached-ok
if grep -q 'detached-ok' "$RESULT_DIR/exec_detached_verify.txt"; then
  pass "detached exec completed"
else
  fail "detached exec did not complete"
fi

REPEAT_OK=1
: >"$RESULT_DIR/repeated-exec.txt"
for i in $(seq 1 12); do
  if ! container exec "$LIFE_ID" sh -c "echo repeat-$i" >>"$RESULT_DIR/repeated-exec.txt" 2>&1; then
    REPEAT_OK=0
    break
  fi
done
if ((REPEAT_OK)); then
  pass "repeated exec reuses stdio ports"
else
  fail "repeated exec failed"
fi

log "PTY compatibility: establish resize delivery, then check three sizes without retries"
if run_pty_resize_probe "$LIFE_ID" --mode compatibility >"$RESULT_DIR/pty-resize.txt" 2>&1; then
  pass "PTY established-session resize (three sizes, no measured retries)"
else
  fail "PTY established-session resize; see pty-resize.txt"
fi

# Use a fresh exec so established-session setup cannot prime this diagnostic.
log "PTY startup diagnostic: independent exec (non-gating unless --require-pty-startup)"
if run_pty_resize_probe "$LIFE_ID" --mode startup >"$RESULT_DIR/pty-resize-startup.txt" 2>&1; then
  PTY_STARTUP_STATUS="PASS"
  pass "PTY startup diagnostic"
else
  PTY_STARTUP_STATUS="FAIL"
  if ((REQUIRE_PTY_STARTUP)); then
    fail "PTY startup diagnostic; see pty-resize-startup.txt"
  else
    warn "PTY startup diagnostic failed; not a runtime compatibility gate; see pty-resize-startup.txt"
  fi
fi

expect_success stats_before container stats --no-stream --format json "$LIFE_ID"
expect_success stats_traffic container exec "$LIFE_ID" ping -c 8 -W 2 1.1.1.1
expect_success stats_after container stats --no-stream --format json "$LIFE_ID"
if python3 - "$RESULT_DIR/stats_before.txt" "$RESULT_DIR/stats_after.txt" >"$RESULT_DIR/stats-check.txt" 2>&1 <<'PY'
import json
import re
import sys


def load(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    match = re.search(r"(\[\s*\{.*?\}\s*\])", text, re.S)
    if not match:
        raise RuntimeError(f"no JSON array found in {path}")
    values = json.loads(match.group(1))
    if not values:
        raise RuntimeError(f"empty stats in {path}")
    return values[0]

before = load(sys.argv[1])
after = load(sys.argv[2])
for key in ("memoryUsageBytes", "memoryLimitBytes", "cpuUsageUsec", "networkRxBytes", "networkTxBytes", "numProcesses"):
    if after.get(key) is None:
        raise RuntimeError(f"missing {key}: {after}")
rx_before = before.get("networkRxBytes") or 0
tx_before = before.get("networkTxBytes") or 0
rx_after = after["networkRxBytes"]
tx_after = after["networkTxBytes"]
print(f"rx: {rx_before} -> {rx_after}")
print(f"tx: {tx_before} -> {tx_after}")
if rx_after <= rx_before or tx_after <= tx_before:
    raise RuntimeError("network counters did not increase after ping traffic")
PY
then
  pass "container stats includes increasing network Rx/Tx"
else
  fail "container stats network counters"
fi

expect_success graceful_stop container stop --time 5 "$LIFE_ID"
if wait_for_state "$LIFE_ID" stopped 10; then
  pass "graceful stop reached stopped"
else
  fail "graceful stop did not reach stopped"
fi
expect_success lifecycle_delete container delete "$LIFE_ID"
if wait_for_runtime_cleanup "$LIFE_ID" 10; then
  pass "graceful-stop runtime cleanup"
else
  fail "graceful-stop runtime cleanup"
fi
check_no_new_network_dirs graceful_stop

# SIGKILL path.
KILL_ID="$PREFIX-kill"
register_container "$KILL_ID"
expect_success kill_run container run -d --name "$KILL_ID" --runtime "$RUNTIME" --network "$NETWORK" \
  "$IMAGE" sh -c 'while :; do sleep 1; done'
if wait_for_state "$KILL_ID" running 10; then
  pass "kill container running"
else
  fail "kill container did not reach running"
fi
expect_success kill_sigkill container kill --signal KILL "$KILL_ID"
if wait_for_state "$KILL_ID" stopped 10; then
  pass "SIGKILL reached stopped"
else
  fail "SIGKILL did not reach stopped"
fi
expect_success kill_delete container delete "$KILL_ID"
if wait_for_runtime_cleanup "$KILL_ID" 10; then
  pass "SIGKILL runtime cleanup"
else
  fail "SIGKILL runtime cleanup"
fi
check_no_new_network_dirs sigkill

# Repeated create/delete cycles catch leaked helpers and socket directories.
CYCLE_OK=1
for i in $(seq 1 "$CYCLES"); do
  id="$PREFIX-cycle-$i"
  register_container "$id"
  if ! run_capture "cycle-$i" container run --rm --name "$id" --runtime "$RUNTIME" --network "$NETWORK" "$IMAGE" true; then
    CYCLE_OK=0
    break
  fi
  if ! wait_for_runtime_cleanup "$id" 10; then
    CYCLE_OK=0
    echo "runtime cleanup failed for $id" >>"$RESULT_DIR/cycle-$i.txt"
    break
  fi
done
if ((CYCLE_OK)); then
  pass "$CYCLES repeated create/delete cycles"
else
  fail "repeated create/delete cycles"
fi
check_no_new_network_dirs cycles

# Memory-reclamation regression: 1920 MiB container + 128 MiB runtime overhead = 2 GiB VM,
# with 1 GiB of incompressible tmpfs data.
MEM_ID="$PREFIX-memory"
register_container "$MEM_ID"
expect_success memory_run container run -d --name "$MEM_ID" --runtime "$RUNTIME" --network "$NETWORK" \
  --memory 1920M --shm-size 1200M "$IMAGE" sh -c 'trap "exit 0" TERM; while :; do sleep 1; done'
if wait_for_state "$MEM_ID" running 10; then
  pass "memory container running"
else
  fail "memory container did not reach running"
fi

capture_host_memory before 0 "$MEM_ID"
expect_success memory_before container exec "$MEM_ID" sh -c "grep -E '^(MemFree|MemAvailable|Shmem):' /proc/meminfo; df -k /dev/shm"
expect_success memory_allocate container exec "$MEM_ID" sh -c \
  'dd if=/dev/urandom of=/dev/shm/reclaim.bin bs=1M count=1024; grep -E "^(MemFree|MemAvailable|Shmem):" /proc/meminfo'
sample_host_memory_for held 20 "$MEM_ID"
expect_success memory_held container exec "$MEM_ID" sh -c "grep -E '^(MemFree|MemAvailable|Shmem):' /proc/meminfo; wc -c /dev/shm/reclaim.bin"
expect_success memory_release container exec "$MEM_ID" sh -c \
  'rm -f /dev/shm/reclaim.bin; sync; grep -E "^(MemFree|MemAvailable|Shmem):" /proc/meminfo'
sample_host_memory_for released "$MEMORY_OBSERVE_SECONDS" "$MEM_ID"
expect_success memory_after container exec "$MEM_ID" sh -c "grep -E '^(MemFree|MemAvailable|Shmem):' /proc/meminfo; test ! -e /dev/shm/reclaim.bin"
expect_success memory_health container exec "$MEM_ID" sh -c 'echo memory-health-ok'

if [[ -n "$APP_ROOT" ]]; then
  MEMORY_BUNDLE="${APP_ROOT%/}/containers/$MEM_ID"
  copy_if_readable "$MEMORY_BUNDLE/boot.log" "$RESULT_DIR/memory-boot.log"
  copy_if_readable "$MEMORY_BUNDLE/krun-vmm.log" "$RESULT_DIR/memory-krun-vmm.log"
  for helper_log in "$MEMORY_BUNDLE"/krun-vmnet-*.log; do
    [[ -r "$helper_log" ]] || continue
    cp "$helper_log" "$RESULT_DIR/memory-$(basename "$helper_log")"
  done
fi

if python3 - "$RESULT_DIR/memory_allocate.txt" "$RESULT_DIR/memory_after.txt" >"$RESULT_DIR/memory-guest-check.txt" 2>&1 <<'PY'
import re
import sys


def shmem_kib(path: str) -> int:
    text = open(path, encoding="utf-8").read()
    values = [int(value) for value in re.findall(r"^Shmem:\s+(\d+)\s+kB", text, re.M)]
    if not values:
        raise RuntimeError(f"no Shmem value in {path}")
    return values[-1]

held = shmem_kib(sys.argv[1])
released = shmem_kib(sys.argv[2])
print(f"Shmem KiB: held={held} released={released}")
if held < 900_000:
    raise RuntimeError("workload did not hold approximately 1 GiB of tmpfs memory")
if released > 200_000:
    raise RuntimeError("guest did not release the tmpfs allocation")
PY
then
  pass "guest released the 1 GiB memory workload"
else
  fail "guest memory workload/release"
fi

expect_success memory_stop container stop --time 5 "$MEM_ID"
expect_success memory_delete container delete "$MEM_ID"
if wait_for_runtime_cleanup "$MEM_ID" 10; then
  pass "memory-test runtime cleanup"
else
  fail "memory-test runtime cleanup"
fi
check_no_new_network_dirs memory

# Collect Apple control-plane and plugin logs covering the entire run.
END_LOCAL="$(date '+%Y-%m-%d %H:%M:%S')"
{
  echo "finished_local=$END_LOCAL"
  echo "failures=$FAILURES"
  echo "warnings=$WARNINGS"
  echo "pty_startup=$PTY_STARTUP_STATUS"
} >>"$RESULT_DIR/run.env"

/usr/bin/log show --start "$START_LOCAL" --end "$END_LOCAL" --info --debug \
  --predicate 'subsystem == "com.apple.container"' \
  >"$RESULT_DIR/system-logs.txt" 2>&1 || true

grep -E "$PREFIX|allocated attachment|released session" "$RESULT_DIR/system-logs.txt" \
  >"$RESULT_DIR/network-lifecycle.txt" || true

grep -F 'runtime lifecycle' "$RESULT_DIR/system-logs.txt" \
  | grep -F "$PREFIX" >"$RESULT_DIR/runtime-lifecycle.txt" || true

grep -F 'resize ' "$RESULT_DIR/runtime-lifecycle.txt" \
  >"$RESULT_DIR/pty-resize-runtime.txt" || true

capture_runtime_state "$RESULT_DIR/runtime-state-final.txt"
check_no_new_network_dirs final

cat >"$RESULT_DIR/SUMMARY.txt" <<SUMMARY
runtime=$RUNTIME
network=$NETWORK
image=$IMAGE
prefix=$PREFIX
cycles=$CYCLES
memory_observe_seconds=$MEMORY_OBSERVE_SECONDS
failures=$FAILURES
warnings=$WARNINGS
pty_startup=$PTY_STARTUP_STATUS
require_pty_startup=$REQUIRE_PTY_STARTUP

Key files:
  results.txt                 PASS/FAIL results and non-gating WARN diagnostics
  runtime-lifecycle.txt       runtime monotonic lifecycle trace
  network-lifecycle.txt       Apple network allocation/release events
  stats-before/after.txt      stats including network counters
  pty-resize.txt              bounded setup, three no-retry resizes, and cleanup
  pty-resize-startup.txt      separate startup diagnostic; recovery remains a failure
  pty-resize-runtime.txt      resize receipt and RPC completion/failure trace
  libkrun-checkout.txt        observed dependency HEAD, dirty state, built dylib hashes
  libkrun-dylib.txt           actual installed dylib hash and recorded hash
  libkrun-otool.txt           installed dylib framework linkage
  memory-host.txt             vm_stat/swap/helper RSS samples every 5 seconds
  memory-krun-vmm.log         VMM log preserved before deleting the memory VM
  memory-allocate/after.txt   guest Shmem evidence before/after release
  runtime-state-*.txt         helper/socket leak evidence
SUMMARY

mkdir -p "$RESULT_ROOT"
tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
trap - EXIT INT TERM
cleanup

log "archive: $ARCHIVE"
if ((FAILURES)); then
  log "$FAILURES validation check(s) failed"
  exit 1
fi
if ((WARNINGS)); then
  log "$WARNINGS non-gating diagnostic warning(s); see results.txt"
fi
log "all required runtime regression checks passed"
