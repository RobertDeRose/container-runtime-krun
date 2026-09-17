#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"
VOLUME_SIZE="256M"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_logs_clean.sh [options]

Validate persistent container logs and filesystem trim through Apple Container's public CLI.

Options:
  --install          Build/install this checkout and restart Apple Container.
  --runtime NAME     Runtime name (default: container-runtime-krun).
  --image IMAGE      Image (default: alpine:3.20).
  --result-root DIR  Output directory (default: validation-results).
  -h, --help         Show help.
USAGE
}
while (($#)); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --runtime) RUNTIME="${2:?missing runtime}"; shift 2 ;;
    --image) IMAGE="${2:?missing image}"; shift 2 ;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in container mise git tar; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-logs-clean-${STAMP}-$$"
LOG_ID="$PREFIX-log"
CLEAN_ID="$PREFIX-clean"
VOLUME="$PREFIX-volume"
OUT="$RESULT_ROOT/logs-clean-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-logs-clean-${STAMP}-$$.tar.gz"
mkdir -p "$OUT"
FAILURES=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); echo "PASS: $*" | tee -a "$OUT/results.txt"; }
fail() { FAILURES=$((FAILURES + 1)); echo "FAIL: $*" | tee -a "$OUT/results.txt" >&2; }
run() {
  local name="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    local status=$?
    printf '\nexit_status=%d\n' "$status"
    return "$status"
  } >"$OUT/$name.txt" 2>&1
}
require_run() {
  local name="$1" label="$2"
  shift 2
  if run "$name" "$@"; then
    pass "$label"
  else
    fail "$label"
    finish
    exit 1
  fi
}
cleanup() {
  set +e
  container delete --force "$LOG_ID" >/dev/null 2>&1 || true
  container delete --force "$CLEAN_ID" >/dev/null 2>&1 || true
  container volume delete "$VOLUME" >/dev/null 2>&1 || true
}
finish() {
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "passes=$PASSES"
    echo "failures=$FAILURES"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  } >"$OUT/SUMMARY.txt"
  container list --all >"$OUT/container-list-final.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
    | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
    | grep -v grep >"$OUT/runtime-processes-final.txt" || true
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
  echo "archive: $ARCHIVE"
}
trap cleanup EXIT INT TERM

{
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "runtime=$RUNTIME"
  echo "image=$IMAGE"
} >"$OUT/environment.txt"

if ((INSTALL)); then
  require_run mise_doctor "mise run doctor" mise run doctor
  require_run mise_check "mise run check" mise run check
  require_run mise_test "mise run test" mise run test
  require_run mise_install "mise run install" mise run install
  require_run system_stop "container system stop" container system stop
  require_run system_start "container system start" container system start
fi

# Detached init output must still be connected to the persistent bundle log.
require_run log_start "log test container started" \
  container run -d --name "$LOG_ID" --runtime "$RUNTIME" --network none "$IMAGE" \
    sh -c 'printf "krun-log-stdout\n"; printf "krun-log-stderr\n" >&2; trap "exit 0" TERM; while :; do sleep 1; done'

log_deadline=$((SECONDS + 15))
while ((SECONDS < log_deadline)); do
  container logs "$LOG_ID" >"$OUT/container-logs-running.txt" 2>&1 || true
  if grep -Fq 'krun-log-stdout' "$OUT/container-logs-running.txt" \
    && grep -Fq 'krun-log-stderr' "$OUT/container-logs-running.txt"; then
    break
  fi
  sleep 0.2
done
if grep -Fq 'krun-log-stdout' "$OUT/container-logs-running.txt" \
  && grep -Fq 'krun-log-stderr' "$OUT/container-logs-running.txt"; then
  pass "container logs persists detached stdout and stderr"
else
  fail "container logs persists detached stdout and stderr"
fi

require_run log_stop "log test container stopped" container stop "$LOG_ID"
if run container_logs_stopped container logs "$LOG_ID" \
  && grep -Fq 'krun-log-stdout' "$OUT/container_logs_stopped.txt" \
  && grep -Fq 'krun-log-stderr' "$OUT/container_logs_stopped.txt"; then
  pass "container logs remains readable after stop"
else
  fail "container logs remains readable after stop"
fi
require_run log_delete "log test container deleted" container delete "$LOG_ID"

# Exercise fstrim on both the writable rootfs and one writable Apple volume.
require_run volume_create "clean test volume created" container volume create -s "$VOLUME_SIZE" "$VOLUME"
require_run clean_start "clean test container started" \
  container run -d --name "$CLEAN_ID" --runtime "$RUNTIME" --network none \
    -v "$VOLUME:/data" "$IMAGE" sleep 300
require_run clean_seed "rootfs and volume seeded with reclaimable blocks" \
  container exec "$CLEAN_ID" sh -c \
    'dd if=/dev/zero of=/trim-root.bin bs=1M count=32 >/dev/null 2>&1; dd if=/dev/zero of=/data/trim-volume.bin bs=1M count=32 >/dev/null 2>&1; sync; rm /trim-root.bin /data/trim-volume.bin; sync'
require_run clean_running "container clean trims writable rootfs and volume" container clean "$CLEAN_ID"
require_run clean_health "container remains usable after clean" container exec "$CLEAN_ID" sh -c 'printf clean-health-ok'
require_run clean_stop "clean test container stopped" container stop "$CLEAN_ID"
if run clean_stopped container clean "$CLEAN_ID"; then
  fail "container clean rejects stopped containers"
else
  pass "container clean rejects stopped containers"
fi
require_run clean_delete "clean test container deleted" container delete "$CLEAN_ID"
require_run volume_delete "clean test volume deleted" container volume delete "$VOLUME"

finish
trap - EXIT INT TERM
((FAILURES == 0))
