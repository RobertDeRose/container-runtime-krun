#!/bin/bash
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_ROOT="$REPO_ROOT/validation-results"
USE_SUDO=0

usage() {
  cat <<'USAGE'
Usage: scripts/validate_vmnet_direct.sh [options]

Probe whether a process signed like KrunVMMHelper can create and consume its
own macOS 26 vmnet_network_ref without com.apple.vm.networking, then drop back
to the invoking uid/gid while retaining a usable vmnet interface.

Options:
  --sudo             Also run the decisive host/shared probes as root.
  --result-root DIR  Output directory root (default: validation-results).
  -h, --help         Show this help.

The normal-user probes are diagnostic: success means no privilege change is
needed, while VMNET_INVALID_ACCESS is expected on systems that require either
root or com.apple.vm.networking. With --sudo, both root probes must create/start
vmnet as root, permanently drop back to the invoking uid/gid, write a frame
through vmnet, and stop the interface after the privilege drop for this
experiment to pass.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sudo)
      USE_SUDO=1
      shift
      ;;
    --result-root)
      [[ $# -ge 2 ]] || { echo "--result-root requires a value" >&2; exit 2; }
      RESULT_ROOT="$2"
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

case "$RESULT_ROOT" in
  /*) ;;
  *) RESULT_ROOT="$REPO_ROOT/$RESULT_ROOT" ;;
esac

for command in xcrun codesign sw_vers git tar awk grep tee id; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done
if [[ "$USE_SUDO" -eq 1 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo "required command not found: sudo" >&2
    exit 1
  }
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_NAME="vmnet-direct-$TIMESTAMP-$$"
CALLER_UID="$(id -u)"
CALLER_GID="$(id -g)"
OUT="$RESULT_ROOT/$RUN_NAME"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-$RUN_NAME.tar.gz"
PROBE="$OUT/vmnet-direct-probe"
mkdir -p "$OUT"

PASSES=0
FAILURES=0

pass() {
  PASSES=$((PASSES + 1))
  printf 'PASS: %s\n' "$*" | tee -a "$OUT/results.txt"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$*" | tee -a "$OUT/results.txt" >&2
}

info() {
  printf 'INFO: %s\n' "$*" | tee -a "$OUT/results.txt"
}

capture() {
  local name="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    local rc=$?
    printf '\nexit_status=%d\n' "$rc"
    return "$rc"
  } >"$OUT/$name.txt" 2>&1
}

compile_probe() {
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)" || return 1
  capture compile \
    xcrun --sdk macosx clang \
      -std=c11 \
      -Wall -Wextra -Werror \
      -O2 \
      -fblocks \
      -mmacosx-version-min=26.0 \
      -isysroot "$sdk_path" \
      "$REPO_ROOT/scripts/vmnet_direct_probe.c" \
      -framework vmnet \
      -framework CoreFoundation \
      -o "$PROBE"
}

record_probe() {
  local scope="$1"
  local mode="$2"
  local logfile="$OUT/${scope}-${mode}.txt"
  local rc

  if [[ "$scope" == "root" ]]; then
    capture "${scope}-${mode}" sudo "$PROBE" --mode "$mode" \
      --drop-uid "$CALLER_UID" --drop-gid "$CALLER_GID"
    rc=$?
  else
    capture "${scope}-${mode}" "$PROBE" --mode "$mode"
    rc=$?
  fi

  if [[ "$scope" == "user" ]]; then
    if [[ "$rc" -eq 0 ]]; then
      pass "normal-user $mode vmnet create/start works without com.apple.vm.networking"
    elif grep -q 'VMNET_INVALID_ACCESS' "$logfile"; then
      info "normal-user $mode vmnet access rejected as expected without entitlement"
    else
      info "normal-user $mode probe failed with exit $rc; root probe determines feasibility"
    fi
    return 0
  fi

  if [[ "$rc" -ne 0 ]]; then
    fail "root $mode vmnet create/start"
    return 0
  fi
  if ! grep -q '^euid=0$' "$logfile"; then
    fail "root $mode probe ran with effective uid 0"
  else
    pass "root $mode probe ran with effective uid 0"
  fi
  if ! grep -q '^network_create_status=VMNET_SUCCESS' "$logfile"; then
    fail "root $mode network reference creation"
  else
    pass "root $mode network reference creation"
  fi
  if ! grep -q '^interface_start_status=VMNET_SUCCESS' "$logfile"; then
    fail "root $mode interface start with same-process network reference"
  else
    pass "root $mode interface start with same-process network reference"
  fi
  if ! grep -q "^post_drop_euid=$CALLER_UID$" "$logfile" \
    || ! grep -q "^post_drop_egid=$CALLER_GID$" "$logfile"; then
    fail "root $mode drops to invoking uid/gid"
  else
    pass "root $mode drops to invoking uid/gid"
  fi
  if ! grep -q '^root_regain_blocked=1$' "$logfile"; then
    fail "root $mode privilege drop is permanent"
  else
    pass "root $mode privilege drop is permanent"
  fi
  if ! grep -q '^post_drop_network_query=1$' "$logfile"; then
    fail "root $mode network reference remains queryable after privilege drop"
  else
    pass "root $mode network reference remains queryable after privilege drop"
  fi
  if ! grep -q '^post_drop_vmnet_write_status=VMNET_SUCCESS' "$logfile" \
    || ! grep -q '^post_drop_vmnet_write_count=1$' "$logfile"; then
    fail "root $mode vmnet data plane remains writable after privilege drop"
  else
    pass "root $mode vmnet data plane remains writable after privilege drop"
  fi
  if ! grep -Eq '^ipv6_prefix=[^:]|^ipv6_prefix=.*:' "$logfile" \
    || grep -q '^ipv6_prefix=::$' "$logfile" \
    || grep -q '^ipv6_prefix_length=0$' "$logfile"; then
    fail "root $mode vmnet reports an IPv6 prefix"
  else
    pass "root $mode vmnet reports an IPv6 prefix"
  fi
  if ! grep -q '^probe_complete=1$' "$logfile"; then
    fail "root $mode interface teardown"
  else
    pass "root $mode interface teardown"
  fi
}

{
  echo "timestamp_utc=$TIMESTAMP"
  echo "macos=$(sw_vers -productVersion 2>/dev/null || true)"
  echo "build=$(sw_vers -buildVersion 2>/dev/null || true)"
  echo "arch=$(uname -m)"
  echo "git_head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  echo "sudo_requested=$USE_SUDO"
  echo "caller_uid=$CALLER_UID"
  echo "caller_gid=$CALLER_GID"
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  echo "sdk_path=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  echo "clang=$(xcrun --sdk macosx --find clang 2>/dev/null || true)"
} >"$OUT/run.env"

if ! compile_probe; then
  fail "compile vmnet direct probe"
else
  pass "compile vmnet direct probe"
fi

if [[ ! -x "$PROBE" ]]; then
  fail "probe executable exists"
else
  pass "probe executable exists"
fi

if [[ -x "$PROBE" ]]; then
  if capture sign codesign --force --sign - \
    --entitlements "$REPO_ROOT/signing/hypervisor.entitlements" "$PROBE"; then
    pass "sign probe with KrunVMMHelper entitlement set"
  else
    fail "sign probe with KrunVMMHelper entitlement set"
  fi

  codesign -d --entitlements :- "$PROBE" >"$OUT/probe-entitlements.txt" 2>&1 || true
  if grep -q 'com.apple.security.hypervisor' "$OUT/probe-entitlements.txt" \
    && ! grep -q 'com.apple.vm.networking' "$OUT/probe-entitlements.txt"; then
    pass "probe has hypervisor entitlement and no vm networking entitlement"
  else
    fail "probe entitlement contract"
  fi

  record_probe user host
  record_probe user shared

  if [[ "$USE_SUDO" -eq 1 ]]; then
    if sudo -v; then
      pass "sudo authorization"
      record_probe root host
      record_probe root shared
    else
      fail "sudo authorization"
    fi
  else
    info "root probes skipped; rerun with --sudo for a decisive privilege result"
  fi
fi

{
  echo "passes=$PASSES"
  echo "failures=$FAILURES"
  echo "sudo_requested=$USE_SUDO"
  if [[ "$USE_SUDO" -eq 1 && "$FAILURES" -eq 0 ]]; then
    echo "conclusion=root vmnet setup plus permanent privilege drop with retained data-plane access is viable"
  elif [[ "$USE_SUDO" -eq 1 ]]; then
    echo "conclusion=root vmnet privilege-drop retention was not proven"
  else
    echo "conclusion=normal-user result only; root feasibility is untested"
  fi
  echo "git_head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
} >"$OUT/SUMMARY.txt"

mkdir -p "$RESULT_ROOT"
tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$RUN_NAME"
printf 'archive=%s\n' "$ARCHIVE" | tee -a "$OUT/results.txt"

if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
if [[ "$USE_SUDO" -eq 0 ]]; then
  exit 2
fi
exit 0
