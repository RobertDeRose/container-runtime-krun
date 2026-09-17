#!/bin/bash
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK=""
MANAGED_NETWORK="krun"
IMAGE="alpine:3.20"
OUTPUT_ROOT="$REPO_ROOT/validation-results"
INSTALL=0
RUNTIME="container-runtime-krun"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_networking.sh [options]

Validate allocationOnly networking and collect diagnostics for packet flow,
explicit network selection, bootstrap latency, and cleanup.

Options:
  --install           Build/install this checkout and restart Apple Container first.
  --network NAME      Existing explicit network to use (default: Apple default network).
  --image IMAGE       Probe image (default: alpine:3.20).
  --output DIR        Result directory root (default: validation-results).
  -h, --help          Show this help.

Without --network, the primary probe uses Apple Container's default-network request.
The runtime uses a compatible built-in default directly or creates/uses `krun`
when the built-in network is incompatible. On macOS 26+, the default invocation
also verifies explicit compatible and incompatible `--network` CLI selection.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --network)
      [[ $# -ge 2 ]] || { echo "--network requires a value" >&2; exit 2; }
      NETWORK="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "--image requires a value" >&2; exit 2; }
      IMAGE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$OUTPUT_ROOT" in
  /*) ;;
  *) OUTPUT_ROOT="$REPO_ROOT/$OUTPUT_ROOT" ;;
esac

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_NAME="networking-$TIMESTAMP-$$"
OUT="$OUTPUT_ROOT/$RUN_NAME"
ARCHIVE="$OUTPUT_ROOT/container-runtime-krun-$RUN_NAME.tar.gz"
CONTAINER_ID="krun-net-$TIMESTAMP-$$"
mkdir -p "$OUT"

FAILED=0
RUN_PID=""
SAMPLER_PID=""
BASELINE_ID=""
SELECTION_SUFFIX="$(date -u +%Y%m%d%H%M%S)-$$"
EXPLICIT_COMPATIBLE_CONTAINER="krun-ci-ok-$SELECTION_SUFFIX"
EXPLICIT_INCOMPATIBLE_CONTAINER="krun-ci-bad-$SELECTION_SUFFIX"
EXPLICIT_INCOMPATIBLE_NETWORK="krun-ci-bad-$SELECTION_SUFFIX"
EXPLICIT_INCOMPATIBLE_NETWORK_CREATED=0

quote_command() {
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

capture() {
  local name="$1"
  shift
  {
    printf '$'
    quote_command "$@"
    "$@"
    local rc=$?
    printf '\nexit_status=%d\n' "$rc"
    return "$rc"
  } >"$OUT/$name.txt" 2>&1
}

record_step() {
  local name="$1"
  shift
  echo "==> $name"
  if capture "$name" "$@"; then
    printf '%s=0\n' "$name" >>"$OUT/status.env"
  else
    local rc=$?
    printf '%s=%d\n' "$name" "$rc" >>"$OUT/status.env"
    FAILED=1
    echo "    failed (exit $rc); continuing to collect diagnostics"
  fi
  return 0
}

monotonic_ns() {
  python3 -c 'import time; print(time.monotonic_ns())'
}

capture_runtime_state() {
  local destination="$1"
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "--- processes ---"
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -E '[c]ontainer-runtime-krun|[c]ontainer-krun-vmm-helper|[v]mnet-helper' \
      || true
    echo "--- krun network directories ---"
    local directory socket
    for directory in /tmp/container-krun-net-*; do
      [[ -d "$directory" ]] || continue
      ls -ld "$directory" 2>/dev/null || true
      for socket in "$directory"/*.sock; do
        [[ -S "$socket" ]] || continue
        echo "socket=$socket"
      done
    done
  } >"$destination" 2>&1
}

sample_runtime() {
  local run_pid="$1"
  local destination="$2"
  : >"$destination"
  while kill -0 "$run_pid" 2>/dev/null; do
    {
      echo "=== $(date '+%Y-%m-%dT%H:%M:%S%z') ==="
      /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
        | grep -E '[c]ontainer-runtime-krun|[c]ontainer-krun-vmm-helper|[v]mnet-helper' \
        || true
      local directory socket
      for directory in /tmp/container-krun-net-*; do
        [[ -d "$directory" ]] || continue
        for socket in "$directory"/*.sock; do
          [[ -S "$socket" ]] || continue
          echo "socket=$socket"
        done
      done
      echo
    } >>"$destination" 2>&1
    sleep 0.25
  done
}

copy_if_readable() {
  local source="$1"
  local destination="$2"
  if [[ -r "$source" ]]; then
    cp "$source" "$destination"
  fi
}

assert_container_uses_network() {
  local step="$1"
  local container_id="$2"
  local network="$3"
  local json="$OUT/$step.json"
  local stderr="$OUT/$step.stderr"
  local rc

  echo "==> $step"
  container inspect "$container_id" >"$json" 2>"$stderr"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s=%d\n' "$step" "$rc" >>"$OUT/status.env"
    FAILED=1
    echo "    failed to inspect container (exit $rc)"
    return 0
  fi

  if python3 - "$json" "$network" <<'PY_ASSERT'
import json
import sys

path, expected = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    payload = json.load(stream)

if len(payload) != 1:
    raise SystemExit(f"expected one inspected container, got {len(payload)}")

attachments = payload[0].get("configuration", {}).get("networks", [])
actual = [item.get("network") for item in attachments]
if actual != [expected]:
    raise SystemExit(f"expected configured network {[expected]!r}, got {actual!r}")
PY_ASSERT
  then
    printf '%s=0\n' "$step" >>"$OUT/status.env"
  else
    rc=$?
    printf '%s=%d\n' "$step" "$rc" >>"$OUT/status.env"
    FAILED=1
    echo "    failed: container configuration did not preserve explicit network $network"
  fi
  return 0
}

run_explicit_network_cli_tests() {
  local incompatible_output="$OUT/explicit_incompatible_run.txt"
  local incompatible_rc
  local create_rc

  record_step explicit_compatible_network_inspect \
    container network inspect "$MANAGED_NETWORK"
  record_step explicit_compatible_run \
    container run \
      --name "$EXPLICIT_COMPATIBLE_CONTAINER" \
      --runtime "$RUNTIME" \
      --network "$MANAGED_NETWORK" \
      "$IMAGE" true
  assert_container_uses_network \
    explicit_compatible_container_network \
    "$EXPLICIT_COMPATIBLE_CONTAINER" \
    "$MANAGED_NETWORK"
  record_step explicit_compatible_container_delete \
    container delete "$EXPLICIT_COMPATIBLE_CONTAINER"

  echo "==> explicit_incompatible_network_create"
  if capture explicit_incompatible_network_create \
    container network create \
      --plugin container-network-vmnet \
      --option variant=reserved \
      "$EXPLICIT_INCOMPATIBLE_NETWORK"; then
    printf 'explicit_incompatible_network_create=0\n' >>"$OUT/status.env"
    EXPLICIT_INCOMPATIBLE_NETWORK_CREATED=1
  else
    create_rc=$?
    printf 'explicit_incompatible_network_create=%d\n' "$create_rc" >>"$OUT/status.env"
    FAILED=1
    echo "    failed (exit $create_rc); skipping incompatible-network run"
    return 0
  fi

  record_step explicit_incompatible_network_inspect \
    container network inspect "$EXPLICIT_INCOMPATIBLE_NETWORK"

  {
    printf '$'
    quote_command container run \
      --name "$EXPLICIT_INCOMPATIBLE_CONTAINER" \
      --runtime "$RUNTIME" \
      --network "$EXPLICIT_INCOMPATIBLE_NETWORK" \
      "$IMAGE" true
    container run \
      --name "$EXPLICIT_INCOMPATIBLE_CONTAINER" \
      --runtime "$RUNTIME" \
      --network "$EXPLICIT_INCOMPATIBLE_NETWORK" \
      "$IMAGE" true
    incompatible_rc=$?
    printf '\nexit_status=%d\n' "$incompatible_rc"
  } >"$incompatible_output" 2>&1

  if [[ "$incompatible_rc" -eq 0 ]]; then
    echo "explicit incompatible network unexpectedly succeeded" >>"$incompatible_output"
    printf 'explicit_incompatible_run=1\n' >>"$OUT/status.env"
    FAILED=1
  elif ! grep -Fq \
    "network $EXPLICIT_INCOMPATIBLE_NETWORK is incompatible with container-runtime-krun" \
    "$incompatible_output"; then
    echo "missing actionable incompatible-network error" >>"$incompatible_output"
    printf 'explicit_incompatible_run=1\n' >>"$OUT/status.env"
    FAILED=1
  elif ! grep -Fq 'expected plugin container-network-vmnet, mode nat, and option variant=allocationOnly' \
    "$incompatible_output"; then
    echo "missing expected compatibility requirements" >>"$incompatible_output"
    printf 'explicit_incompatible_run=1\n' >>"$OUT/status.env"
    FAILED=1
  elif ! grep -Fq 'variant reserved' "$incompatible_output"; then
    echo "missing discovered incompatible variant" >>"$incompatible_output"
    printf 'explicit_incompatible_run=1\n' >>"$OUT/status.env"
    FAILED=1
  else
    printf 'explicit_incompatible_run=0\n' >>"$OUT/status.env"
  fi

  capture explicit_incompatible_container_inspect \
    container inspect "$EXPLICIT_INCOMPATIBLE_CONTAINER" || true
  if container inspect "$EXPLICIT_INCOMPATIBLE_CONTAINER" >/dev/null 2>&1; then
    record_step explicit_incompatible_container_delete \
      container delete "$EXPLICIT_INCOMPATIBLE_CONTAINER"
  fi
  record_step explicit_incompatible_network_delete \
    container network delete "$EXPLICIT_INCOMPATIBLE_NETWORK"
  EXPLICIT_INCOMPATIBLE_NETWORK_CREATED=0
}

on_interrupt() {
  echo "interrupted; attempting best-effort cleanup" >&2
  if [[ -n "$SAMPLER_PID" ]]; then
    kill "$SAMPLER_PID" 2>/dev/null || true
  fi
  if [[ -n "$RUN_PID" ]]; then
    kill "$RUN_PID" 2>/dev/null || true
  fi
  container stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  container delete "$CONTAINER_ID" >/dev/null 2>&1 || true
  if [[ -n "$BASELINE_ID" ]]; then
    container stop "$BASELINE_ID" >/dev/null 2>&1 || true
    container delete "$BASELINE_ID" >/dev/null 2>&1 || true
  fi
  container stop "$EXPLICIT_COMPATIBLE_CONTAINER" >/dev/null 2>&1 || true
  container delete "$EXPLICIT_COMPATIBLE_CONTAINER" >/dev/null 2>&1 || true
  container stop "$EXPLICIT_INCOMPATIBLE_CONTAINER" >/dev/null 2>&1 || true
  container delete "$EXPLICIT_INCOMPATIBLE_CONTAINER" >/dev/null 2>&1 || true
  if [[ "$EXPLICIT_INCOMPATIBLE_NETWORK_CREATED" -eq 1 ]]; then
    container network delete "$EXPLICIT_INCOMPATIBLE_NETWORK" >/dev/null 2>&1 || true
  fi
  exit 130
}
trap on_interrupt INT TERM

cd "$REPO_ROOT"
: >"$OUT/status.env"

DEFAULT_EFFECTIVE_NETWORK="default"
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] && ((MACOS_MAJOR >= 26)); then
  DEFAULT_EFFECTIVE_NETWORK="$MANAGED_NETWORK"
fi
if [[ -z "$NETWORK" || "$NETWORK" == "default" ]]; then
  EFFECTIVE_NETWORK="$DEFAULT_EFFECTIVE_NETWORK"
else
  EFFECTIVE_NETWORK="$NETWORK"
fi

{
  echo "timestamp_utc=$TIMESTAMP"
  echo "container_id=$CONTAINER_ID"
  echo "network=${NETWORK:-<default>}"
  echo "effective_network=$EFFECTIVE_NETWORK"
  echo "image=$IMAGE"
  echo "runtime=$RUNTIME"
  echo "install_requested=$INSTALL"
} >"$OUT/run.env"

capture_runtime_state "$OUT/runtime-state-before.txt"

record_step uname uname -a
record_step sw_vers sw_vers
record_step container_version container --version
record_step swift_version swift --version
record_step python_version python3 --version
record_step git_head git rev-parse HEAD
record_step git_status git status --short --branch
record_step brew_dependencies brew list --versions llvm lld xz vmnet-helper
record_step system_status_before container system status --format json
if [[ -n "$NETWORK" ]]; then
  record_step network_inspect_before container network inspect "$NETWORK"
else
  capture builtin_network_inspect_before container network inspect default || true
  capture managed_network_inspect_before container network inspect "$MANAGED_NETWORK" || true
fi
record_step mise_doctor mise run doctor
record_step mise_check mise run check
record_step mise_test mise run test

if [[ "$INSTALL" -eq 1 ]]; then
  record_step mise_install mise run install
  record_step container_system_stop container system stop
  record_step container_system_start container system start
  record_step system_status_after_restart container system status --format json
fi

STATUS_JSON="$OUT/system-status.json"
if container system status --format json >"$STATUS_JSON" 2>"$OUT/system-status.stderr"; then
  APP_ROOT="$(python3 - "$STATUS_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
print(payload.get("appRoot") or (payload.get("paths") or {}).get("appRoot") or "")
PY
)"
  LOG_ROOT="$(python3 - "$STATUS_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
print(payload.get("logRoot") or (payload.get("paths") or {}).get("logRoot") or "")
PY
)"
  INSTALL_ROOT="$(python3 - "$STATUS_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
print(payload.get("installRoot") or (payload.get("paths") or {}).get("installRoot") or "")
PY
)"
else
  APP_ROOT=""
  LOG_ROOT=""
  INSTALL_ROOT=""
  FAILED=1
fi

{
  echo "app_root=$APP_ROOT"
  echo "log_root=$LOG_ROOT"
  echo "install_root=$INSTALL_ROOT"
} >>"$OUT/run.env"

if [[ -n "$INSTALL_ROOT" ]]; then
  PLUGIN_DIR="$INSTALL_ROOT/libexec/container-plugins/container-runtime-krun"
  {
    echo "plugin_dir=$PLUGIN_DIR"
    shasum -a 256 \
      "$PLUGIN_DIR/config.toml" \
      "$PLUGIN_DIR/bin/container-runtime-krun" \
      "$PLUGIN_DIR/bin/container-krun-vmm-helper" 2>&1 || true
    codesign -dvvv "$PLUGIN_DIR/bin/container-runtime-krun" 2>&1 || true
    codesign -dvvv --entitlements :- "$PLUGIN_DIR/bin/container-krun-vmm-helper" 2>&1 || true
  } >"$OUT/installed-plugin.txt"
fi

if [[ -n "$NETWORK" ]] && ! container network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "network '$NETWORK' is unavailable; skipping the packet-flow run" | tee "$OUT/network-run-skipped.txt"
  FAILED=1
else
  GUEST_PROBE="$(cat <<'PROBE'
echo "=== address ==="
ip addr show eth0

echo "=== routes ==="
ip route

echo "=== gateway ==="
gateway="$(ip route | awk '$1 == "default" { print $3; exit }')"
echo "gateway=$gateway"
ping -c 1 -W 2 "$gateway"

echo "=== internet ==="
ping -c 1 -W 2 1.1.1.1

echo "=== resolv.conf ==="
cat /etc/resolv.conf

echo "=== DNS ==="
nslookup example.com
PROBE
)"

  START_NS="$(monotonic_ns)"
  START_WALL="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  {
    printf '$'
    if [[ -n "$NETWORK" ]]; then
      quote_command container run --name "$CONTAINER_ID" --runtime "$RUNTIME" \
        --network "$NETWORK" "$IMAGE" sh -euxc '<probe>'
      container run \
        --name "$CONTAINER_ID" \
        --runtime "$RUNTIME" \
        --network "$NETWORK" \
        "$IMAGE" sh -euxc "$GUEST_PROBE"
    else
      quote_command container run --name "$CONTAINER_ID" --runtime "$RUNTIME" \
        "$IMAGE" sh -euxc '<probe>'
      container run \
        --name "$CONTAINER_ID" \
        --runtime "$RUNTIME" \
        "$IMAGE" sh -euxc "$GUEST_PROBE"
    fi
  } >"$OUT/network-run.txt" 2>&1 &
  RUN_PID=$!
  sample_runtime "$RUN_PID" "$OUT/runtime-state-live.txt" &
  SAMPLER_PID=$!

  wait "$RUN_PID"
  RUN_RC=$?
  RUN_PID=""
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""

  END_NS="$(monotonic_ns)"
  END_WALL="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  ELAPSED_MS="$(python3 - "$START_NS" "$END_NS" <<'PY'
import sys
print((int(sys.argv[2]) - int(sys.argv[1])) // 1_000_000)
PY
)"
  {
    echo "network_run_exit=$RUN_RC"
    echo "network_run_elapsed_ms=$ELAPSED_MS"
    echo "network_run_started=$START_WALL"
    echo "network_run_finished=$END_WALL"
  } >>"$OUT/run.env"
  if [[ "$RUN_RC" -ne 0 ]]; then
    FAILED=1
  fi

  record_step container_inspect_after_run container inspect "$CONTAINER_ID"
  capture container_logs_after_run container logs "$CONTAINER_ID" || true
  record_step network_inspect_after_run container network inspect "$EFFECTIVE_NETWORK"

  if [[ -n "$APP_ROOT" ]]; then
    BUNDLE_ROOT="$APP_ROOT/containers/$CONTAINER_ID"
    echo "bundle_root=$BUNDLE_ROOT" >>"$OUT/run.env"
    if [[ -d "$BUNDLE_ROOT" ]]; then
      copy_if_readable "$BUNDLE_ROOT/krun-vmm.log" "$OUT/krun-vmm.log"
      copy_if_readable "$BUNDLE_ROOT/boot.log" "$OUT/boot.log"
      copy_if_readable "$BUNDLE_ROOT/container.log" "$OUT/container.log"
      copy_if_readable "$BUNDLE_ROOT/service.plist" "$OUT/service.plist"
      for logfile in "$BUNDLE_ROOT"/krun-vmnet-*.log; do
        [[ -r "$logfile" ]] || continue
        cp "$logfile" "$OUT/$(basename "$logfile")"
      done
    fi
  fi

  record_step container_delete container delete "$CONTAINER_ID"

  # Give launchd/network cleanup a bounded window to settle, then record what is left.
  CLEANUP_DEADLINE=$(( $(date +%s) + 10 ))
  while [[ $(date +%s) -lt "$CLEANUP_DEADLINE" ]]; do
    if ! /bin/ps -axo command= | grep -F -- "--uuid $CONTAINER_ID" | grep -v grep >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  capture_runtime_state "$OUT/runtime-state-after-delete.txt"

  record_step network_inspect_after_delete container network inspect "$EFFECTIVE_NETWORK"

  # Compare against the same runtime with networking explicitly disabled. This
  # distinguishes libkrun/vminitd startup cost from network-specific startup cost.
  BASELINE_ID="krun-baseline-$TIMESTAMP-$$"
  BASELINE_START_NS="$(monotonic_ns)"
  BASELINE_START_WALL="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  {
    printf '$ container run --name %q --runtime %q --network none %q true\n' \
      "$BASELINE_ID" "$RUNTIME" "$IMAGE"
    container run \
      --name "$BASELINE_ID" \
      --runtime "$RUNTIME" \
      --network none \
      "$IMAGE" true
  } >"$OUT/baseline-run.txt" 2>&1
  BASELINE_RC=$?
  BASELINE_END_NS="$(monotonic_ns)"
  BASELINE_END_WALL="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  BASELINE_ELAPSED_MS="$(python3 - "$BASELINE_START_NS" "$BASELINE_END_NS" <<'PY'
import sys
print((int(sys.argv[2]) - int(sys.argv[1])) // 1_000_000)
PY
)"
  {
    echo "baseline_container_id=$BASELINE_ID"
    echo "baseline_run_exit=$BASELINE_RC"
    echo "baseline_run_elapsed_ms=$BASELINE_ELAPSED_MS"
    echo "baseline_run_started=$BASELINE_START_WALL"
    echo "baseline_run_finished=$BASELINE_END_WALL"
  } >>"$OUT/run.env"
  if [[ "$BASELINE_RC" -ne 0 ]]; then
    FAILED=1
  fi
  record_step baseline_inspect_after_run container inspect "$BASELINE_ID"
  capture baseline_logs_after_run container logs "$BASELINE_ID" || true
  if [[ -n "$APP_ROOT" ]]; then
    BASELINE_BUNDLE_ROOT="$APP_ROOT/containers/$BASELINE_ID"
    echo "baseline_bundle_root=$BASELINE_BUNDLE_ROOT" >>"$OUT/run.env"
    if [[ -d "$BASELINE_BUNDLE_ROOT" ]]; then
      copy_if_readable "$BASELINE_BUNDLE_ROOT/krun-vmm.log" "$OUT/baseline-krun-vmm.log"
      copy_if_readable "$BASELINE_BUNDLE_ROOT/boot.log" "$OUT/baseline-boot.log"
    fi
  fi
  record_step baseline_delete container delete "$BASELINE_ID"
  BASELINE_CLEANUP_DEADLINE=$(( $(date +%s) + 10 ))
  while [[ $(date +%s) -lt "$BASELINE_CLEANUP_DEADLINE" ]]; do
    if ! /bin/ps -axo command= | grep -F -- "--uuid $BASELINE_ID" | grep -v grep >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  capture_runtime_state "$OUT/runtime-state-final.txt"

  if [[ -z "$NETWORK" || "$NETWORK" == "default" ]]; then
    if [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] && ((MACOS_MAJOR >= 26)); then
      run_explicit_network_cli_tests
    else
      echo "explicit custom network CLI selection requires macOS 26 or newer" \
        >"$OUT/explicit-network-selection-skipped.txt"
    fi
  else
    echo "explicit CLI selection subtests require the primary default-network probe" \
      >"$OUT/explicit-network-selection-skipped.txt"
  fi

  # Runtime service logs use Apple's normal per-plugin log root when configured.
  if [[ -n "$LOG_ROOT" ]]; then
    RUNTIME_LOG="$LOG_ROOT/container-runtime-krun-$CONTAINER_ID.log"
    echo "runtime_log=$RUNTIME_LOG" >>"$OUT/run.env"
    copy_if_readable "$RUNTIME_LOG" "$OUT/runtime-plugin.log"
  fi
fi

# Capture Apple Container's own service view as supporting lifecycle/allocation evidence.
CONTAINER_LOG_PATTERN="${CONTAINER_ID}|${BASELINE_ID:-__no_baseline__}"
CONTAINER_LOG_PATTERN="${CONTAINER_LOG_PATTERN}|${EXPLICIT_COMPATIBLE_CONTAINER}|${EXPLICIT_INCOMPATIBLE_CONTAINER}"
NETWORK_LOG_PATTERN="${CONTAINER_LOG_PATTERN}|\[id=${EFFECTIVE_NETWORK}\]|\[id=${MANAGED_NETWORK}\]"
NETWORK_LOG_PATTERN="${NETWORK_LOG_PATTERN}|\[id=${EXPLICIT_INCOMPATIBLE_NETWORK}\]"

capture system_logs container system logs --debug --last 5m || true
if [[ -r "$OUT/system_logs.txt" ]]; then
  grep -E "$CONTAINER_LOG_PATTERN" "$OUT/system_logs.txt" \
    >"$OUT/system-logs-container.txt" 2>/dev/null || true
  grep -E 'allocated attachment|released session' "$OUT/system_logs.txt" \
    | grep -E "$NETWORK_LOG_PATTERN" \
    >"$OUT/system-network-lifecycle.txt" 2>/dev/null || true
fi
if [[ -r "$OUT/system_logs.txt" ]]; then
  grep 'runtime lifecycle' "$OUT/system_logs.txt" \
    | grep -E "$CONTAINER_LOG_PATTERN" \
    >"$OUT/lifecycle.txt" 2>/dev/null || true
elif [[ -r "$OUT/runtime-plugin.log" ]]; then
  grep 'runtime lifecycle' "$OUT/runtime-plugin.log" >"$OUT/lifecycle.txt" 2>/dev/null || true
fi

{
  echo "=== observed runtime/helper PIDs ==="
  if [[ -r "$OUT/runtime-state-live.txt" ]]; then
    awk '/container-runtime-krun|container-krun-vmm-helper|vmnet-helper/ {print $1}' \
      "$OUT/runtime-state-live.txt" | grep -E '^[0-9]+$' | sort -n -u || true
  fi
  echo
  echo "=== observed network sockets ==="
  if [[ -r "$OUT/runtime-state-live.txt" ]]; then
    sed -n 's/^socket=//p' "$OUT/runtime-state-live.txt" | sort -u || true
  fi
} >"$OUT/observed-runtime-resources.txt"

{
  echo "result_directory=$OUT"
  echo "archive=$ARCHIVE"
  echo "overall_exit=$FAILED"
  echo
  echo "Important files:"
  echo "  network-run.txt                 guest packet-flow probe"
  echo "  run.env                         networked/baseline wall and monotonic timings"
  echo "  baseline-run.txt                no-network startup comparison"
  echo "  boot.log / baseline-boot.log    guest kernel/vminitd boot logs"
  echo "  runtime-plugin.log              runtime lifecycle log (when available)"
  echo "  lifecycle.txt                   extracted monotonic lifecycle events"
  echo "  krun-vmnet-0.log                vmnet-helper output"
  echo "  krun-vmm.log                    libkrun/VMM helper output"
  echo "  system-logs-container.txt       Apple Container logs for this container"
  echo "  system-network-lifecycle.txt    Apple allocation/release log events"
  echo "  runtime-state-live.txt          runtime/helper/socket samples while running"
  echo "  runtime-state-after-delete.txt  post-delete leak check"
  echo "  explicit_compatible_run.txt     explicit managed-network CLI success"
  echo "  explicit_incompatible_run.txt   actionable rejection of reserved CLI network"
  echo "  mise_check.txt / mise_test.txt  repository validation"
} >"$OUT/SUMMARY.txt"

mkdir -p "$OUTPUT_ROOT"
tar -czf "$ARCHIVE" -C "$OUTPUT_ROOT" "$RUN_NAME"

cat "$OUT/SUMMARY.txt"
echo
printf 'Created %s\n' "$ARCHIVE"
exit "$FAILED"
