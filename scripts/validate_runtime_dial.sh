#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="python:3.13-alpine"
NETWORK="default"
INSTALL=0
RESULT_ROOT="validation-results"
PORT=43210
UNUSED_PORT=43211

usage() {
  cat <<'USAGE'
Usage: scripts/validate_runtime_dial.sh [options]

Validate RuntimeClient.dial(_:) through the installed Apple Container runtime.

Options:
  --install          Build/install this checkout and restart Apple Container.
  --runtime NAME     Runtime name (default: container-runtime-krun).
  --image IMAGE      Image with Python AF_VSOCK support (default: python:3.13-alpine).
  --network NAME     Network used by the container (default: default).
  --result-root DIR  Output directory (default: validation-results).
  -h, --help         Show help.
USAGE
}

while (($#)); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --runtime) RUNTIME="${2:?missing runtime}"; shift 2 ;;
    --image) IMAGE="${2:?missing image}"; shift 2 ;;
    --network) NETWORK="${2:?missing network}"; shift 2 ;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in container git mise python3 ps swift tar; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
ID="krun-dial-${STAMP}-$$"
OUT="$RESULT_ROOT/runtime-dial-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-runtime-dial-${STAMP}-$$.tar.gz"
mkdir -p "$OUT"
PASSES=0
FAILURES=0

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
wait_cleanup() {
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if ! /bin/ps -axo command= | grep -F -- "$ID" \
      | grep -Eq 'container-runtime-krun|container-krun-vmm-helper'; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}
capture_diagnostics() {
  local label="$1"
  local status_file="$OUT/system-status-$label.json"
  local app_root log_root bundle_root path

  container inspect "$ID" >"$OUT/container-inspect-$label.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= >"$OUT/processes-$label.txt" 2>&1 || true
  container system status --format json >"$status_file" 2>&1 || true
  container system logs --debug --last 10m >"$OUT/system-logs-$label.txt" 2>&1 || true

  app_root="$(python3 - "$status_file" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('')
else:
    print(data.get('appRoot') or (data.get('paths') or {}).get('appRoot') or '')
PY
)"
  log_root="$(python3 - "$status_file" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('')
else:
    print(data.get('logRoot') or (data.get('paths') or {}).get('logRoot') or '')
PY
)"

  if [[ -n "$app_root" ]]; then
    bundle_root="$app_root/containers/$ID"
    for path in "$bundle_root"/krun-vmm.log "$bundle_root"/container.log "$bundle_root"/krun-vmm.json; do
      [[ -r "$path" ]] || continue
      cp "$path" "$OUT/$label-$(basename "$path")"
    done
  fi
  if [[ -n "$log_root" && -r "$log_root/$RUNTIME-$ID.log" ]]; then
    cp "$log_root/$RUNTIME-$ID.log" "$OUT/runtime-plugin-$label.log"
  fi
}
finish() {
  local install_root plugin_provenance
  install_root="$(python3 scripts/install_root.py 2>/dev/null || true)"
  plugin_provenance="$install_root/libexec/container-plugins/container-runtime-krun/lib/libkrun.provenance"
  if [[ -r "$plugin_provenance" ]]; then
    cp "$plugin_provenance" "$OUT/installed-libkrun.provenance"
  fi
  {
    echo "runtime=$RUNTIME"
    echo "image=$IMAGE"
    echo "network=$NETWORK"
    echo "port=$PORT"
    echo "unused_port=$UNUSED_PORT"
    echo "passes=$PASSES"
    echo "failures=$FAILURES"
    echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
    echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
    echo "container_version=$(container --version 2>&1 || true)"
  } >"$OUT/SUMMARY.txt"
  container list --all >"$OUT/container-list-final.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
    | grep -E 'container-runtime-krun|container-krun-vmm-helper' \
    | grep -v grep >"$OUT/runtime-processes-final.txt" || true
  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
  echo "archive: $ARCHIVE"
}
cleanup() {
  container delete --force "$ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

{
  echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "runtime=$RUNTIME"
  echo "image=$IMAGE"
  echo "network=$NETWORK"
} >"$OUT/environment.txt"

if ((INSTALL)); then
  require_run mise_check "mise run check" mise run check
  require_run mise_test "mise run test" mise run test
  require_run mise_install "mise run native:install" mise run native:install
  require_run system_stop "container system stop" container system stop
  require_run system_start "container system start" container system start
fi

PY_SERVER=$(cat <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
if not hasattr(socket, "AF_VSOCK"):
    raise SystemExit("Python does not expose AF_VSOCK")
server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
server.bind((socket.VMADDR_CID_ANY, port))
server.listen(8)
print(f"READY {port}", flush=True)
for index, (expected, response) in enumerate((
    (b"host-one\n", b"guest-one\n"),
    (b"host-two\n", b"guest-two\n"),
    (b"host-three\n", b"guest-three\n"),
), 1):
    connection, peer = server.accept()
    with connection:
        received = b""
        while not received.endswith(b"\n"):
            chunk = connection.recv(4096)
            if not chunk:
                break
            received += chunk
        if received != expected:
            raise SystemExit(f"exchange {index}: expected {expected!r}, got {received!r}")
        connection.sendall(response)
    print(f"EXCHANGE {index} OK peer={peer}", flush=True)
print("DONE", flush=True)
time.sleep(300)
PY
)

if run start \
  container run -d --name "$ID" --runtime "$RUNTIME" --network "$NETWORK" \
    "$IMAGE" python3 -u -c "$PY_SERVER" "$PORT"; then
  pass "dial test container started"
else
  fail "dial test container started"
  capture_diagnostics start-failed
  finish
  exit 1
fi

ready_deadline=$((SECONDS + 20))
while ((SECONDS < ready_deadline)); do
  container logs "$ID" >"$OUT/guest-listener.txt" 2>&1 || true
  grep -Fq "READY $PORT" "$OUT/guest-listener.txt" && break
  sleep 0.2
done
if grep -Fq "READY $PORT" "$OUT/guest-listener.txt"; then
  pass "guest AF_VSOCK listener ready"
else
  fail "guest AF_VSOCK listener ready"
  capture_diagnostics listener-failed
  finish
  exit 1
fi

capture_diagnostics before-dial

if run runtime_client_probe env \
  KRUN_RUNTIME_DIAL_CONTAINER_ID="$ID" \
  KRUN_RUNTIME_DIAL_RUNTIME="$RUNTIME" \
  KRUN_RUNTIME_DIAL_PORT="$PORT" \
  KRUN_RUNTIME_DIAL_UNUSED_PORT="$UNUSED_PORT" \
  swift test --force-resolved-versions --filter runtimeDialBehavioralProbe; then
  pass "RuntimeClient.dial bidirectional/repeat/failure-recovery probe"
else
  fail "RuntimeClient.dial bidirectional/repeat/failure-recovery probe"
fi

container logs "$ID" >"$OUT/guest-listener-after-probe.txt" 2>&1 || true
if grep -Fq 'EXCHANGE 1 OK' "$OUT/guest-listener-after-probe.txt" \
  && grep -Fq 'EXCHANGE 2 OK' "$OUT/guest-listener-after-probe.txt" \
  && grep -Fq 'EXCHANGE 3 OK' "$OUT/guest-listener-after-probe.txt" \
  && grep -Fq 'DONE' "$OUT/guest-listener-after-probe.txt"; then
  pass "guest observed three completed vsock connections"
else
  fail "guest observed three completed vsock connections"
fi

if run post_dial_health container exec "$ID" python3 -c 'print("dial-health-ok")' \
  && grep -Fq 'dial-health-ok' "$OUT/post_dial_health.txt"; then
  pass "container remains usable after dial failure and recovery"
else
  fail "container remains usable after dial failure and recovery"
fi

capture_diagnostics after-dial

if run stop container stop "$ID"; then pass "container stopped"; else fail "container stopped"; fi
if run delete container delete "$ID"; then pass "container deleted"; else fail "container deleted"; fi
if wait_cleanup; then pass "runtime/helper cleanup"; else fail "runtime/helper cleanup"; fi
capture_diagnostics after-delete

finish
trap - EXIT INT TERM
((FAILURES == 0))
