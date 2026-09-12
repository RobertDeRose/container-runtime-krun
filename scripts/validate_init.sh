#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_init.sh [options]

Validate the v0.4 --init implementation through the real Apple Container
control plane.

Options:
  --install          Build/install the checkout and restart Apple Container first.
  --image IMAGE      Test image (default: alpine:3.20).
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
    --image)
      IMAGE="${2:?missing value for --image}"
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

for command in container python3 git make ps tar comm; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-init-${STAMP}-$$"
BASIC_ID="$PREFIX-basic"
EXEC_ID="$PREFIX-exec"
SIGNAL_ID="$PREFIX-signal"
TTY_ID="$PREFIX-tty"
RESULT_DIR="$RESULT_ROOT/init-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-init-${STAMP}-$$.tar.gz"
mkdir -p "$RESULT_DIR"

FAILURES=0
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
  local status
  shift 2
  run_capture "$name" "$@"
  status=$?
  if ((status == expected)); then
    pass "$name exited $expected"
  else
    fail "$name exited $status, expected $expected"
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
  local timeout_seconds="${3:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ "$(container_state "$id" || true)" == "$expected" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_text() {
  local file="$1"
  local text="$2"
  local timeout_seconds="${3:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ -f "$file" ]] && grep -Fq -- "$text" "$file"; then
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
    if ! /bin/ps -axo command= | grep -F -- "$id" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper'; then
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

cleanup_container() {
  local id="$1"
  container delete --force "$id" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  local id
  for id in "${CONTAINERS[@]:-}"; do
    [[ -n "$id" ]] || continue
    cleanup_container "$id"
  done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

finish_validation() {
  container list --all >"$RESULT_DIR/container-list-final.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
    | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
    | grep -v grep >"$RESULT_DIR/runtime-processes-final.txt" || true
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "failures=$FAILURES"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  } >"$RESULT_DIR/SUMMARY.txt"
  mkdir -p "$RESULT_ROOT"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
  log "archive=$ARCHIVE"
}

run_pty_probe() {
  local id="$1"
  python3 - "$id" "$RUNTIME" "$IMAGE" <<'PY'
import os
import pty
import select
import sys
import time

container_id, runtime, image = sys.argv[1:]
command = [
    "container", "run", "--rm", "--name", container_id,
    "--runtime", runtime, "--network", "none", "--init", "-i", "-t",
    image, "sh", "-c", "test -t 0 && test -t 1 && printf 'init-tty-ok\\n'",
]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

output = bytearray()
deadline = time.monotonic() + 30
status = None
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                data = b""
            if data:
                output.extend(data)
        waited, raw_status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = os.waitstatus_to_exitcode(raw_status)
            break
finally:
    if status is None:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        _, raw_status = os.waitpid(pid, 0)
        status = os.waitstatus_to_exitcode(raw_status)
    try:
        os.close(fd)
    except OSError:
        pass

text = output.decode("utf-8", errors="replace")
print(text, end="")
if status != 0 or "init-tty-ok" not in text:
    raise SystemExit(1)
PY
}

log "v0.4 --init validation"
log "runtime=$RUNTIME image=$IMAGE"

list_krun_runtime_dirs >"$RESULT_DIR/initial-runtime-dirs.txt"
git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true

expect_success make_doctor make doctor
expect_success make_check make check
expect_success make_test make test

if ((INSTALL)); then
  if ((FAILURES > 0)); then
    log "build/test prerequisites failed; skipping install and runtime --init checks"
    finish_validation
    exit 1
  fi
  expect_success make_install make install
  if ((FAILURES > 0)); then
    log "install failed; skipping runtime --init checks"
    finish_validation
    exit 1
  fi
  expect_success system_stop container system stop
  expect_success system_start container system start
  if ((FAILURES > 0)); then
    log "Apple Container restart failed; skipping runtime --init checks"
    finish_validation
    exit 1
  fi
fi

# The workload must no longer be PID 1 when --init is active. This proves that
# the mounted vminitd binary, rather than the requested workload, owns PID 1.
CONTAINERS+=("$BASIC_ID")
expect_success init_basic \
  container run --rm --name "$BASIC_ID" --runtime "$RUNTIME" --network none --init \
    "$IMAGE" sh -c 'test "$$" -ne 1; printf "workload-pid=%s pid1=" "$$"; cat /proc/1/comm'
if grep -Fq 'workload-pid=' "$RESULT_DIR/init_basic.txt"; then
  pass "--init inserts a PID 1 wrapper"
else
  fail "--init inserts a PID 1 wrapper"
fi
if wait_for_runtime_cleanup "$BASIC_ID" 15; then
  pass "basic --init runtime cleaned up"
else
  fail "basic --init runtime cleaned up"
fi

# The wrapper must preserve the workload's exit status.
expect_status 37 init_exit_status \
  container run --rm --name "$PREFIX-exit" --runtime "$RUNTIME" --network none --init \
    "$IMAGE" sh -c 'exit 37'
if wait_for_runtime_cleanup "$PREFIX-exit" 15; then
  pass "exit-status --init runtime cleaned up"
else
  fail "exit-status --init runtime cleaned up"
fi

# Stdin still crosses the normal process stdio transport when the workload is
# a child of the minimal init process.
{
  printf '$ printf init-stdin-ok | container run ... --init -i %q cat\n' "$IMAGE"
  printf 'init-stdin-ok\n' | container run --rm --name "$PREFIX-stdin" --runtime "$RUNTIME" \
    --network none --init -i "$IMAGE" cat
  status=${PIPESTATUS[1]}
  printf '\nexit_status=%d\n' "$status"
} >"$RESULT_DIR/init_stdin.txt" 2>&1
if ((status == 0)) && grep -Fq 'init-stdin-ok' "$RESULT_DIR/init_stdin.txt"; then
  pass "--init preserves stdin/stdout"
else
  fail "--init preserves stdin/stdout"
fi
if wait_for_runtime_cleanup "$PREFIX-stdin" 15; then
  pass "stdin --init runtime cleaned up"
else
  fail "stdin --init runtime cleaned up"
fi

# PTY setup must remain attached to the workload through the wrapper.
CONTAINERS+=("$TTY_ID")
if run_pty_probe "$TTY_ID" >"$RESULT_DIR/init_tty.txt" 2>&1; then
  pass "--init preserves terminal stdio"
else
  fail "--init preserves terminal stdio"
fi
if wait_for_runtime_cleanup "$TTY_ID" 15; then
  pass "terminal --init runtime cleaned up"
else
  fail "terminal --init runtime cleaned up"
fi

# Exec processes must remain direct runc exec processes; enabling --init on the
# container must not make exec creation depend on the init wrapper path.
CONTAINERS+=("$EXEC_ID")
cleanup_container "$EXEC_ID"
expect_success init_exec_start \
  container run -d --name "$EXEC_ID" --runtime "$RUNTIME" --network none --init "$IMAGE" sleep 300
if wait_for_state "$EXEC_ID" running 20; then
  pass "--init container reached running state"
else
  fail "--init container reached running state"
fi
expect_success init_exec container exec "$EXEC_ID" sh -c 'printf "init-exec-ok\n"'
if grep -Fq 'init-exec-ok' "$RESULT_DIR/init_exec.txt"; then
  pass "container exec remains usable with --init"
else
  fail "container exec remains usable with --init"
fi
expect_success init_exec_stop container stop "$EXEC_ID"
expect_success init_exec_delete container delete "$EXEC_ID"
if wait_for_runtime_cleanup "$EXEC_ID" 15; then
  pass "exec --init runtime cleaned up"
else
  fail "exec --init runtime cleaned up"
fi

# Create a grandchild that outlives its immediate parent. After it exits there
# must be no zombie adopted by PID 1.
expect_success init_zombie_reaping \
  container run --rm --name "$PREFIX-zombie" --runtime "$RUNTIME" --network none --init \
    "$IMAGE" sh -c '( (sleep 0.1 &) & ); sleep 1; ps -o pid,ppid,stat,comm; ! ps -o pid,ppid,stat,comm | awk '\''$2 == 1 && $3 ~ /^Z/ { found=1 } END { exit found ? 0 : 1 }'\'''
if wait_for_runtime_cleanup "$PREFIX-zombie" 15; then
  pass "zombie-reaping --init runtime cleaned up"
else
  fail "zombie-reaping --init runtime cleaned up"
fi

# Signal forwarding is checked with an attached run so the workload can emit a
# marker and its non-zero exit status can be observed by the host CLI.
CONTAINERS+=("$SIGNAL_ID")
cleanup_container "$SIGNAL_ID"
SIGNAL_OUTPUT="$RESULT_DIR/init_signal_forwarding.txt"
container run --name "$SIGNAL_ID" --runtime "$RUNTIME" --network none --init \
  "$IMAGE" sh -c 'trap '\''printf "signal-forwarded\n"; exit 42'\'' TERM; printf "signal-ready\n"; while :; do sleep 1; done' \
  >"$SIGNAL_OUTPUT" 2>&1 &
SIGNAL_RUN_PID=$!
if wait_for_state "$SIGNAL_ID" running 20 && wait_for_text "$SIGNAL_OUTPUT" signal-ready 20; then
  pass "signal-forwarding workload became ready"
else
  fail "signal-forwarding workload became ready"
fi
expect_success init_signal_send container kill --signal TERM "$SIGNAL_ID"
wait "$SIGNAL_RUN_PID"
SIGNAL_STATUS=$?
printf '\nrun_exit_status=%d\n' "$SIGNAL_STATUS" >>"$SIGNAL_OUTPUT"
if grep -Fq 'signal-forwarded' "$SIGNAL_OUTPUT" && ((SIGNAL_STATUS == 42)); then
  pass "--init forwards TERM and preserves trapped exit status"
else
  fail "--init forwards TERM and preserves trapped exit status"
fi
expect_success init_signal_delete container delete "$SIGNAL_ID"
if wait_for_runtime_cleanup "$SIGNAL_ID" 15; then
  pass "signal-forwarding --init runtime cleaned up"
else
  fail "signal-forwarding --init runtime cleaned up"
fi

list_krun_runtime_dirs >"$RESULT_DIR/final-runtime-dirs.txt"
comm -13 "$RESULT_DIR/initial-runtime-dirs.txt" "$RESULT_DIR/final-runtime-dirs.txt" \
  >"$RESULT_DIR/new-runtime-dirs.txt"
if [[ ! -s "$RESULT_DIR/new-runtime-dirs.txt" ]]; then
  pass "--init validation left no new krun runtime socket directories"
else
  fail "--init validation left new krun runtime socket directories"
fi

finish_validation
trap - EXIT INT TERM
if ((FAILURES > 0)); then
  exit 1
fi
exit 0
