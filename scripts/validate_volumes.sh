#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"
VOLUME_SIZE="128M"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_volumes.sh [options]

Validate v0.3 named and anonymous Apple volumes through libkrun virtio-blk.

Options:
  --install          Build/install the checkout and restart Apple Container first.
  --image IMAGE      Test image (default: alpine:3.20).
  --size SIZE        Named volume size (default: 128M).
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
    --size)
      VOLUME_SIZE="${2:?missing value for --size}"
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
PREFIX="krun-volume-${STAMP}-$$"
VOL1="$PREFIX-one"
VOL2="$PREFIX-two"
PERSIST1="$PREFIX-persist-1"
PERSIST2="$PREFIX-persist-2"
READONLY="$PREFIX-readonly"
MULTI="$PREFIX-multi"
REUSE="$PREFIX-reuse"
ANON="$PREFIX-anon"
RESULT_DIR="$RESULT_ROOT/volumes-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-volumes-${STAMP}-$$.tar.gz"
mkdir -p "$RESULT_DIR"

FAILURES=0
declare -a CONTAINERS=()
declare -a VOLUMES=("$VOL1" "$VOL2")
declare -a ANON_VOLUMES=()

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

list_krun_runtime_dirs() {
  local directory
  for directory in /tmp/ckr-*; do
    [[ -d "$directory" ]] || continue
    printf '%s\n' "$directory"
  done | sort
}

list_volumes() {
  container volume list --quiet 2>/dev/null | sed '/^[[:space:]]*$/d' | sort
}

cleanup_container() {
  local id="$1"
  container delete --force "$id" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  local id volume
  for id in "${CONTAINERS[@]:-}"; do
    [[ -n "$id" ]] || continue
    cleanup_container "$id"
  done
  for volume in "${ANON_VOLUMES[@]:-}" "${VOLUMES[@]:-}"; do
    [[ -n "$volume" ]] || continue
    container volume delete "$volume" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

finish_validation() {
  container list --all >"$RESULT_DIR/container-list-final.txt" 2>&1 || true
  list_volumes >"$RESULT_DIR/volume-list-final.txt" || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
    | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
    | grep -v grep >"$RESULT_DIR/runtime-processes-final.txt" || true
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "volume_size=$VOLUME_SIZE"
    echo "failures=$FAILURES"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  } >"$RESULT_DIR/SUMMARY.txt"
  mkdir -p "$RESULT_ROOT"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
  log "archive=$ARCHIVE"
}

start_container() {
  local id="$1"
  shift
  CONTAINERS+=("$id")
  cleanup_container "$id"
  if run_capture "start-$id" container run -d --name "$id" --runtime "$RUNTIME" --network none "$@"; then
    pass "$id started"
  else
    fail "$id started"
    return 1
  fi
  if wait_for_state "$id" running 20; then
    pass "$id reached running state"
  else
    fail "$id reached running state"
    return 1
  fi
}

stop_delete_container() {
  local id="$1"
  expect_success "stop-$id" container stop "$id"
  expect_success "delete-$id" container delete "$id"
  if wait_for_runtime_cleanup "$id" 15; then
    pass "$id helpers cleaned up"
  else
    fail "$id helpers cleaned up"
  fi
}

log "v0.3 volume validation"
log "runtime=$RUNTIME image=$IMAGE size=$VOLUME_SIZE"

list_krun_runtime_dirs >"$RESULT_DIR/initial-runtime-dirs.txt"
list_volumes >"$RESULT_DIR/volume-list-initial.txt" || true

git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true
expect_success make_doctor make doctor
expect_success make_check make check
expect_success make_test make test

if ((INSTALL)); then
  expect_success make_install make install
  if ((FAILURES > 0)); then
    log "build/install prerequisites failed; skipping runtime volume checks"
    finish_validation
    exit 1
  fi
  expect_success system_stop container system stop
  expect_success system_start container system start
  if ((FAILURES > 0)); then
    log "Apple Container restart failed; skipping runtime volume checks"
    finish_validation
    exit 1
  fi
fi

expect_success create_volume_one container volume create -s "$VOLUME_SIZE" "$VOL1"
expect_success create_volume_two container volume create -s "$VOLUME_SIZE" "$VOL2"
expect_success inspect_volume_one container volume inspect "$VOL1"

# Named-volume persistence across container destruction/recreation.
start_container "$PERSIST1" -v "$VOL1:/data" "$IMAGE" sleep 300
expect_success persist_write container exec "$PERSIST1" sh -c 'printf "persistent-volume-data\n" >/data/value.txt; sync'
stop_delete_container "$PERSIST1"

start_container "$PERSIST2" -v "$VOL1:/data" "$IMAGE" sleep 300
if [[ "$(container exec "$PERSIST2" cat /data/value.txt 2>/dev/null || true)" == "persistent-volume-data" ]]; then
  pass "named volume data persisted across containers"
else
  fail "named volume data persisted across containers"
fi
stop_delete_container "$PERSIST2"

# Read-only exposure must preserve reads and reject writes.
start_container "$READONLY" -v "$VOL1:/data:ro" "$IMAGE" sleep 300
if [[ "$(container exec "$READONLY" cat /data/value.txt 2>/dev/null || true)" == "persistent-volume-data" ]]; then
  pass "read-only volume remains readable"
else
  fail "read-only volume remains readable"
fi
expect_failure readonly_write container exec "$READONLY" sh -c 'printf nope >/data/should-not-exist.txt'
if container exec "$READONLY" test ! -e /data/should-not-exist.txt >/dev/null 2>&1; then
  pass "read-only volume rejected mutation"
else
  fail "read-only volume rejected mutation"
fi
stop_delete_container "$READONLY"

# Two independent block-backed volumes in one VM.
start_container "$MULTI" -v "$VOL1:/one" -v "$VOL2:/two" "$IMAGE" sleep 300
if [[ "$(container exec "$MULTI" cat /one/value.txt 2>/dev/null || true)" == "persistent-volume-data" ]]; then
  pass "first volume mounted in multi-volume container"
else
  fail "first volume mounted in multi-volume container"
fi
expect_success multi_second_write container exec "$MULTI" sh -c 'printf "second-volume-data\n" >/two/value.txt; sync'
if [[ "$(container exec "$MULTI" cat /two/value.txt 2>/dev/null || true)" == "second-volume-data" ]]; then
  pass "second volume is independently writable"
else
  fail "second volume is independently writable"
fi

# Copy and statistics must continue to work with attached volume disks.
printf 'copy-to-volume\n' >"$RESULT_DIR/copy-source.txt"
expect_success copy_into_volume container copy "$RESULT_DIR/copy-source.txt" "$MULTI:/one/copied.txt"
if [[ "$(container exec "$MULTI" cat /one/copied.txt 2>/dev/null || true)" == "copy-to-volume" ]]; then
  pass "copyIn works with attached volumes"
else
  fail "copyIn works with attached volumes"
fi
expect_success copy_out_of_volume container copy "$MULTI:/one/copied.txt" "$RESULT_DIR/copied-from-volume.txt"
if [[ "$(cat "$RESULT_DIR/copied-from-volume.txt" 2>/dev/null || true)" == "copy-to-volume" ]]; then
  pass "copyOut works with attached volumes"
else
  fail "copyOut works with attached volumes"
fi
expect_success stats_with_volumes container stats --no-stream "$MULTI"
stop_delete_container "$MULTI"

# The same Apple volume may be exposed more than once without attaching the
# same ext4 image twice. Per-destination read-only semantics must still hold.
start_container "$REUSE" -v "$VOL1:/rw" -v "$VOL1:/ro:ro" "$IMAGE" sleep 300
expect_success reused_volume_write container exec "$REUSE" sh -c 'printf "shared-view\n" >/rw/shared.txt; sync'
if [[ "$(container exec "$REUSE" cat /ro/shared.txt 2>/dev/null || true)" == "shared-view" ]]; then
  pass "reused volume destinations share one backing filesystem"
else
  fail "reused volume destinations share one backing filesystem"
fi
expect_failure reused_volume_ro_write container exec "$REUSE" sh -c 'printf nope >/ro/readonly.txt'
printf 'copy-shared-view\n' >"$RESULT_DIR/copy-reused-source.txt"
expect_success copy_into_reused_rw container copy "$RESULT_DIR/copy-reused-source.txt" "$REUSE:/rw/copied.txt"
if [[ "$(container exec "$REUSE" cat /ro/copied.txt 2>/dev/null || true)" == "copy-shared-view" ]]; then
  pass "copyIn follows reused volume staging mount"
else
  fail "copyIn follows reused volume staging mount"
fi
expect_failure copy_into_reused_ro container copy "$RESULT_DIR/copy-reused-source.txt" "$REUSE:/ro/should-not-copy.txt"
if container exec "$REUSE" test ! -e /ro/should-not-copy.txt >/dev/null 2>&1; then
  pass "copyIn preserves per-destination read-only semantics"
else
  fail "copyIn preserves per-destination read-only semantics"
fi
stop_delete_container "$REUSE"

# Anonymous Apple volume: detect the newly allocated name so cleanup remains
# owned by Apple's volume API rather than by the runtime validator.
list_volumes >"$RESULT_DIR/volume-list-before-anon.txt"
start_container "$ANON" -v /anon "$IMAGE" sleep 300
list_volumes >"$RESULT_DIR/volume-list-after-anon.txt"
comm -13 "$RESULT_DIR/volume-list-before-anon.txt" "$RESULT_DIR/volume-list-after-anon.txt" \
  >"$RESULT_DIR/anonymous-volume-names.txt"
discovered_anon=()
while IFS= read -r volume; do
  [[ -n "$volume" ]] || continue
  discovered_anon+=("$volume")
done <"$RESULT_DIR/anonymous-volume-names.txt"
if ((${#discovered_anon[@]} == 1)); then
  ANON_VOLUMES+=("${discovered_anon[0]}")
  pass "anonymous volume allocated through Apple volume service"
else
  fail "anonymous volume allocation could not be identified uniquely"
fi
expect_success anonymous_write container exec "$ANON" sh -c 'printf "anonymous-data\n" >/anon/value.txt; sync'
if [[ "$(container exec "$ANON" cat /anon/value.txt 2>/dev/null || true)" == "anonymous-data" ]]; then
  pass "anonymous volume is readable and writable"
else
  fail "anonymous volume is readable and writable"
fi
stop_delete_container "$ANON"
if ((${#discovered_anon[@]} == 1)); then
  expect_success inspect_anonymous_after_container_delete container volume inspect "${discovered_anon[0]}"
fi

# Verify persistence of the second named volume after its first VM is gone.
start_container "$PREFIX-vol2-readback" -v "$VOL2:/data" "$IMAGE" sleep 300
if [[ "$(container exec "$PREFIX-vol2-readback" cat /data/value.txt 2>/dev/null || true)" == "second-volume-data" ]]; then
  pass "second named volume persisted across VM recreation"
else
  fail "second named volume persisted across VM recreation"
fi
stop_delete_container "$PREFIX-vol2-readback"

# Delete through Apple's volume service, not runtime-owned storage.
for volume in "${ANON_VOLUMES[@]:-}" "$VOL1" "$VOL2"; do
  [[ -n "$volume" ]] || continue
  if run_capture "delete-volume-${volume}" container volume delete "$volume"; then
    pass "volume $volume deleted through Apple volume service"
  else
    fail "volume $volume deleted through Apple volume service"
  fi
done
ANON_VOLUMES=()
VOLUMES=()

list_krun_runtime_dirs >"$RESULT_DIR/final-runtime-dirs.txt"
comm -13 "$RESULT_DIR/initial-runtime-dirs.txt" "$RESULT_DIR/final-runtime-dirs.txt" \
  >"$RESULT_DIR/new-runtime-dirs.txt"
if [[ ! -s "$RESULT_DIR/new-runtime-dirs.txt" ]]; then
  pass "volume validation left no new krun runtime socket directories"
else
  fail "volume validation left no new krun runtime socket directories"
fi

finish_validation
trap - EXIT INT TERM
if ((FAILURES > 0)); then
  exit 1
fi
exit 0
