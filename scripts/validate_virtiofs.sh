#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_virtiofs.sh [options]

Validate host bind/virtiofs mounts through the real Apple Container CLI.

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

for command in container python3 git mise ps tar cmp; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-virtiofs-${STAMP}-$$"
CONTAINER_ID="$PREFIX-main"
RESULT_DIR="$RESULT_ROOT/virtiofs-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-virtiofs-${STAMP}-$$.tar.gz"
HOST_ROOT="$RESULT_DIR/host"
RW_DIR="$HOST_ROOT/rw"
RO_DIR="$HOST_ROOT/ro"
VIRTIOFS_DIR="$HOST_ROOT/virtiofs"
mkdir -p "$RW_DIR" "$RO_DIR" "$VIRTIOFS_DIR"

FAILURES=0
PASSES=0

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

expect_failure() {
  local name="$1"
  shift
  if run_capture "$name" "$@"; then
    fail "$name unexpectedly succeeded"
  else
    pass "$name rejected"
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

cleanup() {
  set +e
  container delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

finish_validation() {
  container inspect "$CONTAINER_ID" >"$RESULT_DIR/container-inspect-final.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
    | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
    | grep -v grep >"$RESULT_DIR/runtime-processes-final.txt" || true
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "passes=$PASSES"
    echo "failures=$FAILURES"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  } >"$RESULT_DIR/SUMMARY.txt"
  mkdir -p "$RESULT_ROOT"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
  log "archive=$ARCHIVE"
}

log "host bind/virtiofs validation"
log "runtime=$RUNTIME image=$IMAGE"

git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true
expect_success mise_doctor mise run doctor
expect_success mise_check mise run check
expect_success mise_test mise run test

if ((INSTALL)); then
  expect_success mise_install mise run install
  expect_success system_stop container system stop
  expect_success system_start container system start
fi

printf 'host-rw-initial\n' >"$RW_DIR/from-host.txt"
printf 'host-ro-initial\n' >"$RO_DIR/from-host.txt"
printf 'host-virtiofs-initial\n' >"$VIRTIOFS_DIR/from-host.txt"
printf 'outside-secret\n' >"$HOST_ROOT/outside-secret.txt"
ln -s ../outside-secret.txt "$RW_DIR/escape"
printf 'copy-through-runtime\n' >"$RESULT_DIR/copy-source.txt"

container delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true
if run_capture start_container \
  container run -d \
    --name "$CONTAINER_ID" \
    --runtime "$RUNTIME" \
    --network none \
    --volume "$RW_DIR:/mnt/rw" \
    --mount "type=bind,source=$RO_DIR,target=/mnt/ro,readonly" \
    --mount "type=virtiofs,source=$VIRTIOFS_DIR,target=/mnt/virtiofs" \
    "$IMAGE" sleep 300; then
  pass "container with host shares started"
else
  fail "container with host shares started"
fi

if wait_for_state "$CONTAINER_ID" running 20; then
  pass "container reached running state"
else
  fail "container reached running state"
fi

expect_success inspect_mounts container inspect "$CONTAINER_ID"

if [[ "$(container exec "$CONTAINER_ID" cat /mnt/rw/from-host.txt 2>/dev/null || true)" == "host-rw-initial" ]]; then
  pass "read-write share exposes host data"
else
  fail "read-write share exposes host data"
fi

if [[ "$(container exec "$CONTAINER_ID" cat /mnt/ro/from-host.txt 2>/dev/null || true)" == "host-ro-initial" ]]; then
  pass "read-only bind mount exposes host data"
else
  fail "read-only bind mount exposes host data"
fi

if [[ "$(container exec "$CONTAINER_ID" cat /mnt/virtiofs/from-host.txt 2>/dev/null || true)" == "host-virtiofs-initial" ]]; then
  pass "explicit virtiofs mount exposes host data"
else
  fail "explicit virtiofs mount exposes host data"
fi

expect_success guest_write_explicit_virtiofs \
  container exec "$CONTAINER_ID" sh -c 'printf "guest-virtiofs\n" > /mnt/virtiofs/from-guest.txt'
if [[ "$(cat "$VIRTIOFS_DIR/from-guest.txt" 2>/dev/null || true)" == "guest-virtiofs" ]]; then
  pass "explicit virtiofs guest write is visible on host"
else
  fail "explicit virtiofs guest write is visible on host"
fi

expect_success guest_write_rw \
  container exec "$CONTAINER_ID" sh -c 'printf "guest-write\n" > /mnt/rw/from-guest.txt'
if [[ "$(cat "$RW_DIR/from-guest.txt" 2>/dev/null || true)" == "guest-write" ]]; then
  pass "guest write is visible on host"
else
  fail "guest write is visible on host"
fi

printf 'host-rw-updated\n' >"$RW_DIR/from-host.txt"
if [[ "$(container exec "$CONTAINER_ID" cat /mnt/rw/from-host.txt 2>/dev/null || true)" == "host-rw-updated" ]]; then
  pass "host update is visible in running container"
else
  fail "host update is visible in running container"
fi

expect_failure guest_write_ro \
  container exec "$CONTAINER_ID" sh -c 'printf "denied\n" > /mnt/ro/denied.txt'
if [[ ! -e "$RO_DIR/denied.txt" ]]; then
  pass "read-only mount did not modify host"
else
  fail "read-only mount did not modify host"
fi

# A host symlink that points outside the exposed directory must not make that
# adjacent host file visible through ordinary guest path resolution.
expect_failure host_symlink_escape \
  container exec "$CONTAINER_ID" cat /mnt/rw/escape

expect_success copy_into_rw_share \
  container copy "$RESULT_DIR/copy-source.txt" "$CONTAINER_ID:/mnt/rw/copied.txt"
if cmp -s "$RESULT_DIR/copy-source.txt" "$RW_DIR/copied.txt"; then
  pass "copy into virtiofs share targets host directory"
else
  fail "copy into virtiofs share targets host directory"
fi

expect_success copy_out_of_rw_share \
  container copy "$CONTAINER_ID:/mnt/rw/from-guest.txt" "$RESULT_DIR/copy-out.txt"
if cmp -s "$RW_DIR/from-guest.txt" "$RESULT_DIR/copy-out.txt"; then
  pass "copy out of virtiofs share uses staged share"
else
  fail "copy out of virtiofs share uses staged share"
fi

expect_failure copy_into_ro_share \
  container copy "$RESULT_DIR/copy-source.txt" "$CONTAINER_ID:/mnt/ro/denied-copy.txt"
if [[ ! -e "$RO_DIR/denied-copy.txt" ]]; then
  pass "copy honors read-only virtiofs share"
else
  fail "copy honors read-only virtiofs share"
fi

expect_success stop_container container stop "$CONTAINER_ID"
expect_success delete_container container delete "$CONTAINER_ID"
if wait_for_runtime_cleanup "$CONTAINER_ID" 15; then
  pass "virtiofs helpers cleaned up"
else
  fail "virtiofs helpers cleaned up"
fi

finish_validation
trap - EXIT INT TERM
cleanup

if ((FAILURES > 0)); then
  exit 1
fi
