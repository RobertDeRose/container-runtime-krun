#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
NETWORK="default"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_port_forwarding.sh [options]

Validate v0.2 TCP/UDP published-port forwarding through Apple's SocketForwarder.

Options:
  --install          Build/install the checkout and restart Apple Container.
  --network NAME     Apple allocationOnly network to use (default: Apple default network).
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
    --network)
      NETWORK="${2:?missing value for --network}"
      shift 2
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

for command in container python3 git mise ps; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-ports-${STAMP}-$$"
RESULT_DIR="$RESULT_ROOT/ports-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-ports-${STAMP}-$$.tar.gz"
MAIN_ID="$PREFIX-main"
FAIL_ID="$PREFIX-partial"
mkdir -p "$RESULT_DIR"

FAILURES=0
RESERVER_PID=""
INITIAL_SOCKETS="$RESULT_DIR/initial-sockets.txt"

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

capture_runtime_state() {
  local output="$1"
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo '--- processes ---'
    /bin/ps -axo pid=,ppid=,etime=,rss=,command= \
      | grep -E 'container-runtime-krun|container-krun-vmm-helper|vmnet-helper' \
      | grep -v grep || true
    echo '--- krun network sockets ---'
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

list_network_sockets() {
  local directory socket
  for directory in /tmp/container-krun-net-*; do
    [[ -d "$directory" ]] || continue
    for socket in "$directory"/*.sock; do
      [[ -S "$socket" ]] || continue
      echo "$socket"
    done
  done | sort
}

wait_for_runtime_cleanup() {
  local id="$1"
  local timeout_seconds="${2:-10}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if ! /bin/ps -axo command= | grep -F -- "$id" | grep -Eq 'container-runtime-krun|container-krun-vmm-helper|vmnet-helper'; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

check_no_new_sockets() {
  local name="$1"
  list_network_sockets >"$RESULT_DIR/$name-sockets.txt"
  comm -13 "$INITIAL_SOCKETS" "$RESULT_DIR/$name-sockets.txt" >"$RESULT_DIR/$name-new-sockets.txt"
  if [[ ! -s "$RESULT_DIR/$name-new-sockets.txt" ]]; then
    pass "$name left no new krun Unix sockets"
  else
    fail "$name left new krun Unix sockets"
  fi
}

free_port() {
  local socket_type="$1"
  python3 - "$socket_type" <<'PY'
import socket
import sys
kind = socket.SOCK_STREAM if sys.argv[1] == "tcp" else socket.SOCK_DGRAM
with socket.socket(socket.AF_INET, kind) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

assert_bindable() {
  local socket_type="$1"
  local port="$2"
  python3 - "$socket_type" "$port" <<'PY'
import socket
import sys
kind = socket.SOCK_STREAM if sys.argv[1] == "tcp" else socket.SOCK_DGRAM
with socket.socket(socket.AF_INET, kind) as sock:
    if kind == socket.SOCK_STREAM:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", int(sys.argv[2])))
PY
}

wait_for_tcp() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket
import sys
import time
port = int(sys.argv[1])
payload = b"krun-tcp-ok\n"
deadline = time.monotonic() + 20
last = None
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1) as sock:
            sock.settimeout(1)
            sock.sendall(payload)
            data = b""
            while len(data) < len(payload):
                chunk = sock.recv(len(payload) - len(data))
                if not chunk:
                    break
                data += chunk
        if data != payload:
            raise RuntimeError(f"unexpected TCP payload: {data!r}")
        print(data.decode(), end="")
        raise SystemExit(0)
    except Exception as exc:
        last = exc
        time.sleep(0.1)
raise SystemExit(f"TCP forwarding did not become usable: {last}")
PY
}

wait_for_guest_listeners() {
  local id="$1"
  local timeout_seconds="${2:-60}"
  local output="$RESULT_DIR/guest-listeners.txt"
  local deadline=$((SECONDS + timeout_seconds))
  local status=1

  while ((SECONDS < deadline)); do
    if container exec "$id" sh -c 'netstat -lnptu 2>/dev/null || true' >"$output" 2>&1; then
      if grep -Eq '[:.]8080[[:space:]]' "$output" && grep -Eq '[:.]8081[[:space:]]' "$output"; then
        status=0
        break
      fi
    fi
    sleep 0.25
  done

  {
    echo
    echo '--- processes ---'
    container exec "$id" ps 2>&1 || true
    echo
    echo "listener_wait_status=$status"
  } >>"$output"
  return "$status"
}

check_udp() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket
import sys
import time
port = int(sys.argv[1])
payload = b"krun-udp-ok"
deadline = time.monotonic() + 20
last = None
while time.monotonic() < deadline:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(1)
            sock.sendto(payload, ("127.0.0.1", port))
            data, peer = sock.recvfrom(65535)
        if data != payload:
            raise RuntimeError(f"unexpected UDP payload from {peer}: {data!r}")
        print(data.decode())
        raise SystemExit(0)
    except Exception as exc:
        last = exc
        time.sleep(0.1)
raise SystemExit(f"UDP forwarding did not become usable: {last}")
PY
}

start_reserved_tcp_port() {
  local port_file="$RESULT_DIR/reserved-port.txt"
  rm -f "$port_file"
  OCCUPIED_PORT=""
  python3 - "$port_file" >"$RESULT_DIR/reserved-listener.txt" 2>&1 <<'PY' &
import socket
import sys
import time
path = sys.argv[1]
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(str(sock.getsockname()[1]))
        f.flush()
    while True:
        time.sleep(1)
PY
  RESERVER_PID=$!
  local deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    if [[ -s "$port_file" ]]; then
      OCCUPIED_PORT="$(cat "$port_file")"
      return 0
    fi
    if ! kill -0 "$RESERVER_PID" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

cleanup() {
  set +e
  [[ -n "$RESERVER_PID" ]] && kill "$RESERVER_PID" >/dev/null 2>&1 || true
  container delete --force "$MAIN_ID" >/dev/null 2>&1 || true
  container delete --force "$FAIL_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "results: $RESULT_DIR"
{
  echo "timestamp_utc=$STAMP"
  echo "runtime=$RUNTIME"
  echo "network=$NETWORK"
  echo "image=$IMAGE"
  echo "main_id=$MAIN_ID"
  echo "failure_id=$FAIL_ID"
} >"$RESULT_DIR/run.env"

git rev-parse HEAD >"$RESULT_DIR/git-head.txt" 2>&1 || true
git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true
container --version >"$RESULT_DIR/container-version.txt" 2>&1 || true
container system status --format json >"$RESULT_DIR/system-status.json" 2>&1 || true

if ! container network inspect "$NETWORK" >"$RESULT_DIR/network-inspect.txt" 2>&1; then
  fail "network $NETWORK is not available"
fi

capture_runtime_state "$RESULT_DIR/runtime-state-initial.txt"
list_network_sockets >"$INITIAL_SOCKETS"

expect_success mise_doctor mise run doctor
expect_success mise_check mise run check
expect_success mise_test mise run test

if ((INSTALL)); then
  expect_success mise_install mise run install
  expect_success system_stop container system stop
  expect_success system_start container system start
fi

TCP_PORT="$(free_port tcp)"
UDP_PORT="$(free_port udp)"
{
  echo "tcp=$TCP_PORT"
  echo "udp=$UDP_PORT"
} >"$RESULT_DIR/ports.txt"

GUEST_SCRIPT='set -eu
apk add --no-cache socat >/tmp/apk-socat.log 2>&1
socat TCP4-LISTEN:8080,reuseaddr,fork EXEC:/bin/cat &
socat UDP4-RECVFROM:8081,reuseaddr,fork EXEC:/bin/cat &
while :; do sleep 1; done'

if run_capture main_run container run -d \
  --name "$MAIN_ID" \
  --runtime "$RUNTIME" \
  --network "$NETWORK" \
  --publish "127.0.0.1:${TCP_PORT}:8080/tcp" \
  --publish "127.0.0.1:${UDP_PORT}:8081/udp" \
  "$IMAGE" sh -c "$GUEST_SCRIPT"; then
  pass "published-port container started"
else
  fail "published-port container failed to start"
fi

container inspect "$MAIN_ID" >"$RESULT_DIR/main-inspect.txt" 2>&1 || true
capture_runtime_state "$RESULT_DIR/runtime-state-main-live.txt"
if wait_for_guest_listeners "$MAIN_ID" 60; then
  pass "guest TCP/UDP listeners became ready"
else
  fail "guest TCP/UDP listeners became ready"
fi

if wait_for_tcp "$TCP_PORT" >"$RESULT_DIR/tcp-probe.txt" 2>&1; then
  pass "TCP host publication reaches guest"
else
  fail "TCP host publication reaches guest"
fi

if check_udp "$UDP_PORT" >"$RESULT_DIR/udp-probe.txt" 2>&1; then
  pass "UDP host publication reaches guest"
else
  fail "UDP host publication reaches guest"
fi
container exec "$MAIN_ID" ps >"$RESULT_DIR/guest-processes.txt" 2>&1 || true
container exec "$MAIN_ID" cat /tmp/apk-socat.log >"$RESULT_DIR/guest-apk-socat.txt" 2>&1 || true
container logs "$MAIN_ID" >"$RESULT_DIR/main-container-logs.txt" 2>&1 || true

if run_capture main_stop container stop "$MAIN_ID"; then
  pass "published-port container stopped"
else
  fail "published-port container stopped"
fi
if run_capture main_delete container delete "$MAIN_ID"; then
  pass "published-port container deleted"
else
  fail "published-port container deleted"
fi
if wait_for_runtime_cleanup "$MAIN_ID" 10; then
  pass "published-port runtime helpers cleaned up"
else
  fail "published-port runtime helpers cleaned up"
fi

if assert_bindable tcp "$TCP_PORT" >"$RESULT_DIR/tcp-rebind.txt" 2>&1; then
  pass "TCP host port released after cleanup"
else
  fail "TCP host port released after cleanup"
fi
if assert_bindable udp "$UDP_PORT" >"$RESULT_DIR/udp-rebind.txt" 2>&1; then
  pass "UDP host port released after cleanup"
else
  fail "UDP host port released after cleanup"
fi
capture_runtime_state "$RESULT_DIR/runtime-state-main-after-delete.txt"
check_no_new_sockets main_cleanup

# Verify a bootstrap failure after one successful forwarder bind closes the
# earlier forwarder and still releases VM/network resources.
OCCUPIED_PORT=""
start_reserved_tcp_port || true
PARTIAL_PORT="$(free_port tcp)"
{
  echo "first_bind=$PARTIAL_PORT"
  echo "occupied=$OCCUPIED_PORT"
} >"$RESULT_DIR/partial-bind-ports.txt"

if [[ -z "$OCCUPIED_PORT" ]]; then
  fail "reserved TCP listener started"
else
  pass "reserved TCP listener started"
  run_capture partial_bind_run container run -d \
    --name "$FAIL_ID" \
    --runtime "$RUNTIME" \
    --network "$NETWORK" \
    --publish "127.0.0.1:${PARTIAL_PORT}:8082/tcp" \
    --publish "127.0.0.1:${OCCUPIED_PORT}:8083/tcp" \
    "$IMAGE" sh -c 'while :; do sleep 1; done'
  PARTIAL_STATUS=$?
  if ((PARTIAL_STATUS != 0)); then
    pass "partial bind failure rejected bootstrap"
  else
    fail "partial bind failure rejected bootstrap"
  fi
fi

# The CLI attempts to delete a container whose bootstrap fails; make that
# cleanup explicit/best-effort before checking the runtime-owned resources.
container delete --force "$FAIL_ID" >"$RESULT_DIR/partial-delete.txt" 2>&1 || true
if wait_for_runtime_cleanup "$FAIL_ID" 10; then
  pass "partial-bind runtime helpers cleaned up"
else
  fail "partial-bind runtime helpers cleaned up"
fi
if assert_bindable tcp "$PARTIAL_PORT" >"$RESULT_DIR/partial-first-rebind.txt" 2>&1; then
  pass "forwarder opened before later bind failure was closed"
else
  fail "forwarder opened before later bind failure was closed"
fi
capture_runtime_state "$RESULT_DIR/runtime-state-partial-after-delete.txt"
check_no_new_sockets partial_cleanup

if [[ -n "$RESERVER_PID" ]]; then
  kill "$RESERVER_PID" >/dev/null 2>&1 || true
  wait "$RESERVER_PID" >/dev/null 2>&1 || true
  RESERVER_PID=""
fi

container system logs --debug --last 10m >"$RESULT_DIR/system-logs-container.txt" 2>&1 || true
grep -E "$MAIN_ID|$FAIL_ID|NetworkVmnetHelper|creating port forwarder|closing forwarder|closed forwarder" \
  "$RESULT_DIR/system-logs-container.txt" >"$RESULT_DIR/system-logs-relevant.txt" 2>/dev/null || true
ALLOCATIONS="$(grep -Ec "allocated attachment.*hostname=(${MAIN_ID}|${FAIL_ID})" "$RESULT_DIR/system-logs-container.txt" 2>/dev/null || true)"
RELEASES="$(grep -Ec "NetworkVmnetHelper.*released session.*id=(${NETWORK}|krun)" "$RESULT_DIR/system-logs-container.txt" 2>/dev/null || true)"
{
  echo "test_allocations=$ALLOCATIONS"
  echo "recent_network_releases=$RELEASES"
} >"$RESULT_DIR/network-lifecycle-counts.txt"
if ((ALLOCATIONS >= 2)); then
  pass "Apple network allocations observed for both port tests"
else
  fail "Apple network allocations observed for both port tests"
fi
if ((RELEASES >= 2)); then
  pass "Apple network release events observed"
else
  fail "Apple network release events observed"
fi

capture_runtime_state "$RESULT_DIR/runtime-state-final.txt"
check_no_new_sockets final_cleanup

{
  echo "runtime=$RUNTIME"
  echo "network=$NETWORK"
  echo "image=$IMAGE"
  echo "tcp_port=$TCP_PORT"
  echo "udp_port=$UDP_PORT"
  echo "partial_first_port=$PARTIAL_PORT"
  echo "partial_occupied_port=$OCCUPIED_PORT"
  echo "failures=$FAILURES"
} >"$RESULT_DIR/SUMMARY.txt"

mkdir -p "$RESULT_ROOT"
tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$RESULT_DIR")"
log "archive: $ARCHIVE"

if ((FAILURES > 0)); then
  exit 1
fi
