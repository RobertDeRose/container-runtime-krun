#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_snapshot.sh [options]

Validate running-container snapshot/export through Apple Container's public CLI.

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

for c in container mise git tar python3 ps; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-snapshot-${STAMP}-$$"
ID="$PREFIX-live"
OUT="$RESULT_ROOT/snapshot-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-snapshot-${STAMP}-$$.tar.gz"
mkdir -p "$OUT"
FAILURES=0
PASSES=0
pass(){ PASSES=$((PASSES+1)); echo "PASS: $*" | tee -a "$OUT/results.txt"; }
fail(){ FAILURES=$((FAILURES+1)); echo "FAIL: $*" | tee -a "$OUT/results.txt" >&2; }
run(){ local n="$1"; shift; { printf '$'; printf ' %q' "$@"; printf '\n'; "$@"; local r=$?; printf '\nexit_status=%d\n' "$r"; return "$r"; } >"$OUT/$n.txt" 2>&1; }
wait_cleanup(){ local deadline=$((SECONDS+10)); while ((SECONDS<deadline)); do /bin/ps -axo command= | grep -F -- "$ID" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper' || return 0; sleep .2; done; return 1; }
archive_results(){
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "passes=$PASSES"
    echo "failures=$FAILURES"
  } >"$OUT/SUMMARY.txt"
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
  echo "archive: $ARCHIVE"
}
require_run(){
  local name="$1" label="$2"
  shift 2
  if run "$name" "$@"; then
    pass "$label"
    return 0
  fi
  fail "$label"
  archive_results
  exit 1
}
cleanup(){ container delete --force "$ID" >/dev/null 2>&1 || true; }
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

require_run start "snapshot test container started" \
  container run -d --name "$ID" --runtime "$RUNTIME" --network none "$IMAGE" \
  sh -c 'trap "exit 0" TERM; while :; do sleep 1; done'
require_run seed "seeded root filesystem" \
  container exec "$ID" sh -c 'printf before-export >/snapshot-before.txt; sync'

LIVE_TAR="$OUT/live-export.tar"
run live_export container export --output "$LIVE_TAR" "$ID" && pass "live container export" || fail "live container export"
if tar -tf "$LIVE_TAR" >"$OUT/live-export-list.txt" 2>&1 && grep -q 'snapshot-before.txt' "$OUT/live-export-list.txt"; then
  member="$(grep 'snapshot-before.txt' "$OUT/live-export-list.txt" | head -1)"
  tar -xOf "$LIVE_TAR" "$member" >"$OUT/live-export-value.txt" 2>&1 || true
  grep -qx 'before-export' "$OUT/live-export-value.txt" && pass "export contains pre-freeze data" || fail "export contains pre-freeze data"
else
  fail "export contains snapshot-before.txt"
fi

run post_export_health container exec "$ID" sh -c 'printf after-export >/snapshot-after.txt; cat /snapshot-before.txt /snapshot-after.txt' \
  && pass "container remains writable after export" || fail "container remains writable after export"

SECOND_TAR="$OUT/second-export.tar"
run second_export container export --output "$SECOND_TAR" "$ID" && pass "second live export" || fail "second live export"
if tar -tf "$SECOND_TAR" >"$OUT/second-export-list.txt" 2>&1 && grep -q 'snapshot-after.txt' "$OUT/second-export-list.txt"; then
  pass "second export sees post-first-export writes"
else
  fail "second export sees post-first-export writes"
fi

# Force a caller-side export-output failure after RuntimeClient.snapshotDisk has
# completed. The nonexistent parent makes the final archive move fail; the
# container must already have been thawed before that move is attempted.
run output_failure container export --output "$OUT/missing-parent/export.tar" "$ID"
if [[ $? -ne 0 ]]; then pass "export output failure is reported"; else fail "export output failure is reported"; fi
run after_failure_health container exec "$ID" sh -c 'echo snapshot-health-ok; test -f /snapshot-before.txt' \
  && pass "container remains usable after failed export output" || fail "container remains usable after failed export output"

run stop container stop "$ID" && pass "container stopped" || fail "container stopped"
run delete container delete "$ID" && pass "container deleted" || fail "container deleted"
wait_cleanup && pass "snapshot runtime/helper cleanup" || fail "snapshot runtime/helper cleanup"

archive_results
trap - EXIT INT TERM
((FAILURES==0))
