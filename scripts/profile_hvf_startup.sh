#!/usr/bin/env bash
set -euo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
RESULT_ROOT="validation-results"
TRACE_DURATION="8s"
COMMAND_TIMEOUT_SECONDS=60
INSTALL_TIMEOUT_SECONDS=600
INSTALL_KRUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/profile_hvf_startup.sh [options]

Capture a system-wide Time Profiler trace around one warm container-runtime-krun
startup. The trace keeps the short-lived VMM helper visible from process launch,
including its named fc_vcpu threads.

Options:
  --install-krun        Build/install krun and restart Apple Container first.
  --runtime NAME        Runtime to profile (default: container-runtime-krun).
  --image IMAGE         Warm test image (default: alpine:3.20).
  --trace-duration TIME xctrace recording duration (default: 8s).
  --command-timeout N   Runtime command timeout in seconds (default: 60).
  --install-timeout N   Build/install timeout in seconds (default: 600).
  --result-root DIR     Output directory (default: validation-results).
  -h, --help            Show help.
USAGE
}

while (($#)); do
  case "$1" in
    --install-krun) INSTALL_KRUN=1; shift;;
    --runtime) RUNTIME="${2:?missing runtime}"; shift 2;;
    --image) IMAGE="${2:?missing image}"; shift 2;;
    --trace-duration) TRACE_DURATION="${2:?missing trace duration}"; shift 2;;
    --command-timeout) COMMAND_TIMEOUT_SECONDS="${2:?missing command timeout}"; shift 2;;
    --install-timeout) INSTALL_TIMEOUT_SECONDS="${2:?missing install timeout}"; shift 2;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

for command in container xcrun notifyutil python3 tar mise git codesign shasum; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done
xcrun --find xctrace >/dev/null
[[ "$COMMAND_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "--command-timeout must be positive" >&2; exit 2; }
[[ "$INSTALL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "--install-timeout must be positive" >&2; exit 2; }

# Prevent any command used by the harness from opening an interactive pager.
export PAGER=cat
export GIT_PAGER=cat

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
PREFIX="kp-${STAMP}-$$"
OUT="$RESULT_ROOT/hvf-profile-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-hvf-profile-${STAMP}-$$.tar.gz"
TRACE="$OUT/hvf-startup.trace"
CONTAINER_ID="$PREFIX-startup"
WARM_ID="$PREFIX-warm"
TRACE_PID=""
NOTIFY_PID=""
mkdir -p "$OUT"

cleanup() {
  set +e
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete --force "$CONTAINER_ID" >/dev/null 2>&1 || true
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete --force "$WARM_ID" >/dev/null 2>&1 || true
  [[ -z "$NOTIFY_PID" ]] || kill "$NOTIFY_PID" >/dev/null 2>&1 || true
  [[ -z "$TRACE_PID" ]] || kill "$TRACE_PID" >/dev/null 2>&1 || true
}

on_signal() {
  local status="$1"
  trap - INT TERM
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

package_results() {
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
}

capture_bundle_files() {
  local container_id="$1"
  local prefix="$2"
  local bundle path

  [[ -n "${APP_ROOT:-}" ]] || return 0
  bundle="$APP_ROOT/containers/$container_id"
  echo "bundle=$bundle" >"$OUT/${prefix}-bundle.txt"
  [[ -d "$bundle" ]] || return 0

  find "$bundle" -maxdepth 1 -type f -print | sort >>"$OUT/${prefix}-bundle.txt" 2>/dev/null || true
  for path in "$bundle"/*.log "$bundle"/*.json; do
    [[ -r "$path" ]] || continue
    cp "$path" "$OUT/${prefix}-$(basename "$path")"
  done
}

capture_failure_diagnostics() {
  local container_id="$1"
  local prefix="$2"
  local path
  local predicate='process == "container-krun-vmm-helper" OR process == "container-runtime-krun"'
  predicate+=' OR eventMessage CONTAINS[c] "krun"'

  capture_bundle_files "$container_id" "$prefix"
  run_bounded 5 container inspect "$container_id" >"$OUT/${prefix}-inspect.txt" 2>&1 || true
  /usr/bin/log show --last 5m --style compact --predicate "$predicate" \
    >"$OUT/${prefix}-system-log.txt" 2>&1 || true

  for path in "$HOME"/Library/Logs/DiagnosticReports/container-krun-vmm-helper*.ips; do
    [[ -r "$path" ]] || continue
    cp "$path" "$OUT/${prefix}-$(basename "$path")"
  done
}

wait_for_system() {
  local deadline=$((SECONDS + COMMAND_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    if run_bounded 5 container system status --format json >"$OUT/system-status.json" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "Apple Container did not become ready within ${COMMAND_TIMEOUT_SECONDS}s" >&2
  return 1
}

if ((INSTALL_KRUN)); then
  # Profiling intentionally uses local commits on top of the pinned libkrun checkout. Running the
  # normal libkrun task dependency chain can refresh libkrun:checkout when mise.toml changes, which
  # destroys those commits. Run the existing build/install task bodies without their dependencies.
  libkrun_head_before=$(git -C .build-deps/libkrun rev-parse HEAD)
  rm -f .build-deps/libkrun/target/release/libkrun.*.dylib
  run_bounded "$INSTALL_TIMEOUT_SECONDS" mise run --skip-deps libkrun
  libkrun_head_after=$(git -C .build-deps/libkrun rev-parse HEAD)
  [[ "$libkrun_head_after" == "$libkrun_head_before" ]] || {
    echo "libkrun checkout changed during profiling build: $libkrun_head_before -> $libkrun_head_after" >&2
    exit 1
  }
  built_libkrun=$(find .build-deps/libkrun/target/release -maxdepth 1 -name 'libkrun.*.dylib' -print -quit)
  [[ -r "$built_libkrun" ]] || { echo "instrumented libkrun dylib was not produced" >&2; exit 1; }

  # libkrun is rebuilt independently, but the Swift executables are unchanged by profiling. Preserve
  # their known-good signatures instead of force re-signing them: macOS can reject an ad-hoc signature
  # at exec time even when userspace codesign verification succeeds. The normal sign task is safe here
  # because its only dependency is release:build, which has already been run without the libkrun graph.
  run_bounded "$INSTALL_TIMEOUT_SECONDS" mise run --skip-deps release:build
  run_bounded "$INSTALL_TIMEOUT_SECONDS" mise run --skip-deps sign
  build_dir=".build/arm64-apple-macosx/release"
  runtime_binary="$build_dir/container-runtime-krun"
  helper_binary="$build_dir/container-krun-vmm-helper"
  [[ -x "$runtime_binary" ]] || { echo "runtime release binary is missing" >&2; exit 1; }
  [[ -x "$helper_binary" ]] || { echo "helper release binary is missing" >&2; exit 1; }

  # Cargo/ld emits a signed arm64 dylib. Verify all three images, but do not rewrite their signatures.
  codesign --verify --strict --verbose=2 "$built_libkrun"
  codesign --verify --strict --verbose=2 "$runtime_binary"
  codesign --verify --strict --verbose=2 "$helper_binary"

  run_bounded "$INSTALL_TIMEOUT_SECONDS" mise run --skip-deps install
  install_root=$(python3 scripts/install_root.py)
  plugin_dir="$install_root/libexec/container-plugins/container-runtime-krun"
  installed_runtime="$plugin_dir/bin/container-runtime-krun"
  installed_helper="$plugin_dir/bin/container-krun-vmm-helper"
  installed_libkrun="$plugin_dir/lib/libkrun.dylib"
  provenance="$plugin_dir/lib/libkrun.provenance"
  [[ -r "$provenance" ]] || { echo "installed libkrun provenance is missing" >&2; exit 1; }
  built_libkrun_sha=$(shasum -a 256 "$built_libkrun" | awk '{print $1}')
  installed_libkrun_sha=$(awk -F= '$1 == "sha256" {print $2; exit}' "$provenance")
  [[ -n "$installed_libkrun_sha" ]] || { echo "installed libkrun provenance has no sha256" >&2; exit 1; }
  [[ "$installed_libkrun_sha" == "$built_libkrun_sha" ]] || {
    echo "installed libkrun provenance does not match the instrumented build" >&2
    echo "built:     $built_libkrun_sha" >&2
    echo "installed: $installed_libkrun_sha" >&2
    exit 1
  }

  {
    for path in "$installed_runtime" "$installed_helper" "$installed_libkrun"; do
      echo "== $path =="
      codesign --verify --strict --verbose=4 "$path" 2>&1
      codesign -d --verbose=4 "$path" 2>&1
      codesign -d --entitlements :- "$path" 2>&1 || true
    done
  } >"$OUT/installed-codesign.txt"

  # Exercise the installed helper before restarting Apple Container. With no config it must reach
  # main and return the normal usage error; SIGKILL here means macOS rejected the installed image.
  set +e
  "$installed_helper" >"$OUT/helper-preflight.txt" 2>&1
  helper_preflight_status=$?
  set -e
  if ((helper_preflight_status != 1)) || ! grep -q 'usage: container-krun-vmm-helper CONFIG.json' \
    "$OUT/helper-preflight.txt"; then
    echo "installed helper failed executable preflight (status=$helper_preflight_status)" >&2
    /usr/bin/log show --last 1m --style compact \
      --predicate 'process == "container-krun-vmm-helper" OR eventMessage CONTAINS[c] "code signature"' \
      >"$OUT/helper-preflight-system-log.txt" 2>&1 || true
    package_results
    echo "$ARCHIVE"
    exit 1
  fi

  run_bounded "$COMMAND_TIMEOUT_SECONDS" container system stop
  run_bounded "$COMMAND_TIMEOUT_SECONDS" container system start
fi

wait_for_system
APP_ROOT="$(python3 - "$OUT/system-status.json" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("")
else:
    print(data.get("appRoot") or (data.get("paths") or {}).get("appRoot") or "")
PY
)"

{
  echo "timestamp=$STAMP"
  echo "runtime=$RUNTIME"
  echo "image=$IMAGE"
  echo "trace_duration=$TRACE_DURATION"
  echo "app_root=$APP_ROOT"
  echo "xctrace=$(xcrun --find xctrace)"
  echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
  libkrun_dylib=$(
    find .build-deps/libkrun/target/release -maxdepth 1 -name 'libkrun.*.dylib' -print -quit 2>/dev/null || true
  )
  if [[ -n "$libkrun_dylib" ]]; then
    echo "libkrun_dylib=$libkrun_dylib"
    echo "libkrun_sha256=$(shasum -a 256 "$libkrun_dylib" | awk '{print $1}')"
  fi
  if [[ -n "${provenance:-}" && -r "$provenance" ]]; then
    echo "installed_libkrun_provenance=$provenance"
    awk -F= '$1 == "sha256" {print "installed_libkrun_sha256=" $2; exit}' "$provenance"
  fi
  xcodebuild -version 2>/dev/null || true
} >"$OUT/environment.txt"

run_bounded "$COMMAND_TIMEOUT_SECONDS" \
  container create --name "$WARM_ID" --runtime "$RUNTIME" --network none "$IMAGE" true \
  >"$OUT/warm-create.txt" 2>&1
if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" container start "$WARM_ID" >"$OUT/warm-start.txt" 2>&1; then
  capture_failure_diagnostics "$WARM_ID" "warm"
  run_bounded 5 container system status --format json >"$OUT/system-status-after-warm-failure.json" 2>&1 || true
  install_root=$(python3 scripts/install_root.py 2>/dev/null || true)
  if [[ -n "$install_root" ]]; then
    provenance="$install_root/libexec/container-plugins/container-runtime-krun/lib/libkrun.provenance"
    [[ ! -r "$provenance" ]] || cp "$provenance" "$OUT/installed-libkrun.provenance"
  fi
  package_results
  printf '%s\n' "$ARCHIVE"
  exit 1
fi
capture_bundle_files "$WARM_ID" "warm"
run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete --force "$WARM_ID" >/dev/null 2>&1 || true

# Create the measured container before tracing so the profile focuses on bootstrap/startup rather
# than image resolution and persistent container creation.
run_bounded "$COMMAND_TIMEOUT_SECONDS" \
  container create --name "$CONTAINER_ID" --runtime "$RUNTIME" --network none "$IMAGE" \
    sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' \
    >"$OUT/container-create.txt" 2>&1

NOTIFICATION="com.checkpt.container-runtime-krun.xctrace.$$.started"
notifyutil -q -1 "$NOTIFICATION" >"$OUT/xctrace-notify.txt" 2>&1 &
NOTIFY_PID=$!

xcrun xctrace record \
  --template "Time Profiler" \
  --all-processes \
  --time-limit "$TRACE_DURATION" \
  --output "$TRACE" \
  --notify-tracing-started "$NOTIFICATION" \
  >"$OUT/xctrace-record.txt" 2>&1 &
TRACE_PID=$!

python3 - "$NOTIFY_PID" "$TRACE_PID" <<'PY'
import os
import sys
import time

notify_pid = int(sys.argv[1])
trace_pid = int(sys.argv[2])
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
raise SystemExit("timed out waiting for xctrace to start recording")
PY
wait "$NOTIFY_PID"
NOTIFY_PID=""

date -u '+startup_begin=%Y-%m-%dT%H:%M:%SZ' >>"$OUT/environment.txt"
START_FAILED=0
if ! run_bounded "$COMMAND_TIMEOUT_SECONDS" container start "$CONTAINER_ID" \
  >"$OUT/container-start.txt" 2>&1; then
  START_FAILED=1
fi
sleep 1
capture_bundle_files "$CONTAINER_ID" "startup"
date -u '+startup_end=%Y-%m-%dT%H:%M:%SZ' >>"$OUT/environment.txt"

# Leave the container and bundle in place until xctrace finishes. On failure this preserves the
# helper log; on success it avoids adding teardown work to the startup profile.
wait "$TRACE_PID"
TRACE_PID=""
if ((START_FAILED)); then
  capture_failure_diagnostics "$CONTAINER_ID" "startup"
fi
run_bounded "$COMMAND_TIMEOUT_SECONDS" container delete --force "$CONTAINER_ID" \
  >"$OUT/container-delete.txt" 2>&1 || true

xcrun xctrace export --input "$TRACE" --toc --output "$OUT/trace-toc.xml" \
  >"$OUT/xctrace-export-toc.txt" 2>&1 || true
xcrun xctrace export --input "$TRACE" \
  --xpath '/trace-toc/run[@number="1"]/processes/process[@name="container-krun-vmm-helper"]' \
  --output "$OUT/helper-process.xml" >"$OUT/xctrace-export-helper.txt" 2>&1 || true
xcrun xctrace export --input "$TRACE" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "$OUT/time-profile.xml" >"$OUT/xctrace-export-time-profile.txt" 2>&1 || true

package_results
printf '%s\n' "$ARCHIVE"
((START_FAILED == 0)) || exit 1
