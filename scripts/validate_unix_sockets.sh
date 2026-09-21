#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
NETWORK="default"
IMAGE="python:3.13-alpine"
INSTALL=0
RESULT_ROOT="validation-results"

usage() {
  cat <<'USAGE'
Usage: scripts/validate_unix_sockets.sh [options]

Validate the v0.4 published Unix socket and SSH agent forwarding slice through
the real Apple Container control plane.

Options:
  --install          Build/install the checkout and restart Apple Container first.
  --network NAME     Apple allocationOnly network used by the rollback probe (default: Apple default network).
  --image IMAGE      Test image with python3 (default: python:3.13-alpine).
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

for command in container python3 git mise ps tar comm; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "required command not found: $command" >&2
    exit 1
  fi
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-sock-${STAMP}-$$"
PUB_ID="$PREFIX-pub"
VOLUME_ID="$PREFIX-volume"
VOLUME_NAME="$PREFIX-data"
SSH_EXEC_ID="$PREFIX-ssh-exec"
ROLLBACK_ID="$PREFIX-rollback"
RESULT_DIR="$RESULT_ROOT/unix-sockets-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-unix-sockets-${STAMP}-$$.tar.gz"
HOST_SOCKET_DIR="/tmp/krun-v04-${STAMP}-$$"
HOST_PUBLISHED="$HOST_SOCKET_DIR/published.sock"
HOST_VOLUME_PUBLISHED="$HOST_SOCKET_DIR/volume.sock"
HOST_ROLLBACK="$HOST_SOCKET_DIR/rollback.sock"
HOST_AGENT="$HOST_SOCKET_DIR/agent.sock"
AGENT_LOG="$RESULT_DIR/agent-server.log"
mkdir -p "$RESULT_DIR" "$HOST_SOCKET_DIR"

FAILURES=0
AGENT_PID=""
RESERVER_PID=""
OCCUPIED_PORT=""
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

wait_for_socket() {
  local path="$1"
  local timeout_seconds="${2:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ -S "$path" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_guest_socket() {
  local id="$1"
  local path="$2"
  local timeout_seconds="${3:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if container exec "$id" test -S "$path" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_path_absent() {
  local path="$1"
  local timeout_seconds="${2:-15}"
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if [[ ! -e "$path" && ! -L "$path" ]]; then
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
  container delete --force "$1" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  local id
  for id in "${CONTAINERS[@]:-}"; do
    [[ -n "$id" ]] || continue
    cleanup_container "$id"
  done
  container volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
  if [[ -n "$AGENT_PID" ]]; then
    kill "$AGENT_PID" >/dev/null 2>&1 || true
    wait "$AGENT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RESERVER_PID" ]]; then
    kill "$RESERVER_PID" >/dev/null 2>&1 || true
    wait "$RESERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$HOST_PUBLISHED" "$HOST_VOLUME_PUBLISHED" "$HOST_ROLLBACK" "$HOST_AGENT"
  rmdir "$HOST_SOCKET_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

finish_validation() {
  container list --all >"$RESULT_DIR/container-list-final.txt" 2>&1 || true
  container volume list >"$RESULT_DIR/volume-list-final.txt" 2>&1 || true
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
    with open(path, "w", encoding="utf-8") as output:
        output.write(str(sock.getsockname()[1]))
        output.flush()
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

start_host_agent() {
  rm -f "$HOST_AGENT"
  python3 - "$HOST_AGENT" "$AGENT_LOG" <<'PY' &
import os
import signal
import socket
import sys
import threading

path, log_path = sys.argv[1:]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
os.chmod(path, 0o600)
server.listen(16)
server.settimeout(0.25)
running = True

def stop(*_):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def handle(conn):
    with conn:
        data = conn.recv(65536)
        with open(log_path, "ab") as log:
            log.write(data + b"\n")
        conn.sendall(b"agent:" + data)

try:
    while running:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
finally:
    server.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
PY
  AGENT_PID=$!
  wait_for_socket "$HOST_AGENT" 10
}

host_socket_client() {
  local socket_path="$1"
  local message="$2"
  local expected="$3"
  python3 - "$socket_path" "$message" "$expected" <<'PY'
import socket
import sys
path, message, expected = sys.argv[1:]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(path)
sock.sendall(message.encode())
expected_bytes = expected.encode()
data = bytearray()
while len(data) < len(expected_bytes):
    chunk = sock.recv(len(expected_bytes) - len(data))
    if not chunk:
        break
    data.extend(chunk)
sock.close()
received = bytes(data)
print(received.decode(errors="replace"))
if received != expected_bytes:
    raise SystemExit(f"expected {expected_bytes!r}, got {received!r}")
PY
}

host_socket_concurrency() {
  local socket_path="$1"
  python3 - "$socket_path" <<'PY'
import concurrent.futures
import socket
import sys
path = sys.argv[1]

def one(i):
    payload = f"client-{i}"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(path)
    sock.sendall(payload.encode())
    expected = f"container:{payload}".encode()
    data = bytearray()
    while len(data) < len(expected):
        chunk = sock.recv(len(expected) - len(data))
        if not chunk:
            break
        data.extend(chunk)
    sock.close()
    received = bytes(data)
    if received != expected:
        raise RuntimeError((payload, received))
    return received.decode()

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(one, range(4)))
for result in results:
    print(result)
PY
}

read -r -d '' PY_SERVER <<'PY' || true
import os
import socket

path = os.environ["SOCKET_PATH"]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(16)
print("socket-ready", flush=True)
while True:
    conn, _ = server.accept()
    with conn:
        data = conn.recv(65536)
        conn.sendall(b"container:" + data)
PY
SSH_CLIENT='import os,socket,stat; p=os.environ["SSH_AUTH_SOCK"]; print("ssh-path="+p); print("ssh-mode=%03o" % stat.S_IMODE(os.stat(p).st_mode)); s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(p); s.sendall(b"initial"); print(s.recv(65536).decode()); s.close()'
SSH_EXEC_CLIENT='import os,socket; p=os.environ["SSH_AUTH_SOCK"]; print("ssh-path="+p); s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(p); s.sendall(b"exec"); print(s.recv(65536).decode()); s.close()'

log "v0.4 Unix socket + SSH forwarding validation"
log "runtime=$RUNTIME image=$IMAGE"

list_krun_runtime_dirs >"$RESULT_DIR/initial-runtime-dirs.txt"
git status --short >"$RESULT_DIR/git-status.txt" 2>&1 || true

expect_success mise_doctor mise run doctor
expect_success mise_check mise run check
expect_success mise_test mise run test

if ((INSTALL)); then
  if ((FAILURES > 0)); then
    log "build/test prerequisites failed; skipping install and runtime socket checks"
    finish_validation
    exit 1
  fi
  expect_success mise_install mise run install
  if ((FAILURES > 0)); then
    log "install failed; skipping runtime socket checks"
    finish_validation
    exit 1
  fi
  expect_success system_stop container system stop
  expect_success system_start container system start
  if ((FAILURES > 0)); then
    log "Apple Container restart failed; skipping runtime socket checks"
    finish_validation
    exit 1
  fi
fi

# Published socket: one host listener should proxy repeated and concurrent host
# clients to the Unix socket owned by the container workload.
CONTAINERS+=("$PUB_ID")
cleanup_container "$PUB_ID"
rm -f "$HOST_PUBLISHED"
expect_success published_start \
  container run -d --name "$PUB_ID" --runtime "$RUNTIME" --network none \
    --publish-socket "$HOST_PUBLISHED:/tmp/service.sock" \
    --env SOCKET_PATH=/tmp/service.sock \
    "$IMAGE" python3 -u -c "$PY_SERVER"
if wait_for_state "$PUB_ID" running 20 \
    && wait_for_socket "$HOST_PUBLISHED" 20 \
    && wait_for_guest_socket "$PUB_ID" /tmp/service.sock 20; then
  pass "published Unix socket became ready"
else
  fail "published Unix socket became ready"
fi
if host_socket_client "$HOST_PUBLISHED" alpha container:alpha >"$RESULT_DIR/published-client.txt" 2>&1; then
  pass "published Unix socket relays bidirectional data"
else
  fail "published Unix socket relays bidirectional data"
fi
if host_socket_concurrency "$HOST_PUBLISHED" >"$RESULT_DIR/published-concurrent.txt" 2>&1; then
  pass "published Unix socket handles concurrent host clients"
else
  fail "published Unix socket handles concurrent host clients"
fi
expect_success published_stop container stop "$PUB_ID"
expect_success published_delete container delete "$PUB_ID"
if wait_for_path_absent "$HOST_PUBLISHED" 15; then
  pass "published host socket removed after container cleanup"
else
  fail "published host socket removed after container cleanup"
fi
if wait_for_runtime_cleanup "$PUB_ID" 15; then
  pass "published-socket runtime cleaned up"
else
  fail "published-socket runtime cleaned up"
fi

# A socket inside a block-backed Apple volume must resolve to the volume's
# staging mount rather than the rootfs path hidden by the OCI bind mount.
container volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
expect_success volume_create container volume create "$VOLUME_NAME"
CONTAINERS+=("$VOLUME_ID")
rm -f "$HOST_VOLUME_PUBLISHED"
expect_success volume_socket_start \
  container run -d --name "$VOLUME_ID" --runtime "$RUNTIME" --network none \
    -v "$VOLUME_NAME:/data" \
    --publish-socket "$HOST_VOLUME_PUBLISHED:/data/service.sock" \
    --env SOCKET_PATH=/data/service.sock \
    "$IMAGE" python3 -u -c "$PY_SERVER"
if wait_for_state "$VOLUME_ID" running 20 \
    && wait_for_socket "$HOST_VOLUME_PUBLISHED" 20 \
    && wait_for_guest_socket "$VOLUME_ID" /data/service.sock 20; then
  pass "volume-backed published socket became ready"
else
  fail "volume-backed published socket became ready"
fi
if host_socket_client "$HOST_VOLUME_PUBLISHED" volume container:volume \
  >"$RESULT_DIR/volume-published-client.txt" 2>&1; then
  pass "published socket reaches a Unix socket on an Apple volume"
else
  fail "published socket reaches a Unix socket on an Apple volume"
fi
expect_success volume_socket_stop container stop "$VOLUME_ID"
expect_success volume_socket_delete container delete "$VOLUME_ID"
if wait_for_path_absent "$HOST_VOLUME_PUBLISHED" 15; then
  pass "volume-backed published host socket removed"
else
  fail "volume-backed published host socket removed"
fi
expect_success volume_delete container volume rm "$VOLUME_NAME"

# SSH forwarding uses the same fixed-vsock transport in the reverse direction.
# A fake agent is enough to validate byte transparency, environment injection,
# source permissions, and use by both the initial process and exec processes.
if start_host_agent; then
  pass "host fake SSH agent started"
else
  fail "host fake SSH agent started"
fi
if run_capture ssh_initial env SSH_AUTH_SOCK="$HOST_AGENT" \
  container run --rm --name "$PREFIX-ssh-initial" --runtime "$RUNTIME" --network none --ssh \
    "$IMAGE" python3 -c "$SSH_CLIENT"; then
  if grep -Fq 'ssh-path=/var/host-services/ssh-auth.sock' "$RESULT_DIR/ssh_initial.txt" \
    && grep -Fq 'ssh-mode=600' "$RESULT_DIR/ssh_initial.txt" \
    && grep -Fq 'agent:initial' "$RESULT_DIR/ssh_initial.txt"; then
    pass "SSH agent is forwarded to the initial process with host permissions"
  else
    fail "SSH agent is forwarded to the initial process with host permissions"
  fi
else
  fail "SSH agent initial-process relay command"
fi

CONTAINERS+=("$SSH_EXEC_ID")
cleanup_container "$SSH_EXEC_ID"
expect_success ssh_exec_start env SSH_AUTH_SOCK="$HOST_AGENT" \
  container run -d --name "$SSH_EXEC_ID" --runtime "$RUNTIME" --network none --ssh \
    "$IMAGE" sleep 300
if wait_for_state "$SSH_EXEC_ID" running 20; then
  pass "SSH forwarding container reached running state"
else
  fail "SSH forwarding container reached running state"
fi
if run_capture ssh_exec container exec "$SSH_EXEC_ID" python3 -c "$SSH_EXEC_CLIENT"; then
  if grep -Fq 'ssh-path=/var/host-services/ssh-auth.sock' "$RESULT_DIR/ssh_exec.txt" \
    && grep -Fq 'agent:exec' "$RESULT_DIR/ssh_exec.txt"; then
    pass "container exec inherits SSH agent forwarding"
  else
    fail "container exec inherits SSH agent forwarding"
  fi
else
  fail "container exec SSH relay command"
fi
expect_success ssh_exec_stop container stop "$SSH_EXEC_ID"
expect_success ssh_exec_delete container delete "$SSH_EXEC_ID"
if wait_for_runtime_cleanup "$SSH_EXEC_ID" 15; then
  pass "SSH exec runtime cleaned up"
else
  fail "SSH exec runtime cleaned up"
fi

# Apple's runtime permits --ssh when the launching environment has no usable
# SSH_AUTH_SOCK; the guest variable is still injected but no relay is mounted.
if run_capture ssh_missing_source env -u SSH_AUTH_SOCK \
  container run --rm --name "$PREFIX-ssh-missing" --runtime "$RUNTIME" --network none --ssh \
    "$IMAGE" python3 -c 'import os; p=os.environ.get("SSH_AUTH_SOCK"); print(p); raise SystemExit(0 if p == "/var/host-services/ssh-auth.sock" and not os.path.exists(p) else 1)'; then
  pass "--ssh without host SSH_AUTH_SOCK remains usable and fail-closed at the socket"
else
  fail "--ssh without host SSH_AUTH_SOCK remains usable and fail-closed at the socket"
fi

# Force a failure after KrunVMController.boot() has completed. Published TCP
# forwarders are created only after the VM, vminitd, and Unix socket relays are
# ready, so colliding a host TCP port exercises the rollback path with the
# libkrun-created published Unix listener already live.
CONTAINERS+=("$ROLLBACK_ID")
cleanup_container "$ROLLBACK_ID"
rm -f "$HOST_ROLLBACK"
if ! container network inspect "$NETWORK" >"$RESULT_DIR/rollback-network-inspect.txt" 2>&1; then
  fail "rollback network $NETWORK is available"
elif ! start_reserved_tcp_port; then
  fail "reserved TCP listener started for rollback probe"
else
  pass "reserved TCP listener started for rollback probe"
  if run_capture rollback_after_helper \
    container run --rm --name "$ROLLBACK_ID" --runtime "$RUNTIME" --network "$NETWORK" \
      --publish-socket "$HOST_ROLLBACK:/tmp/rollback.sock" \
      --publish "127.0.0.1:${OCCUPIED_PORT}:8083/tcp" \
      "$IMAGE" true; then
    fail "post-boot socket-forwarder collision unexpectedly succeeded"
  elif grep -Eq 'Unknown option|Usage: container run' "$RESULT_DIR/rollback_after_helper.txt"; then
    fail "rollback probe failed in CLI parsing instead of runtime bootstrap"
  else
    pass "post-boot socket-forwarder collision rejected bootstrap"
  fi
fi
if wait_for_path_absent "$HOST_ROLLBACK" 15; then
  pass "bootstrap rollback removes the published host socket"
else
  fail "bootstrap rollback removes the published host socket"
fi
if wait_for_runtime_cleanup "$ROLLBACK_ID" 15; then
  pass "bootstrap rollback cleans runtime/helper processes"
else
  fail "bootstrap rollback cleans runtime/helper processes"
fi
if [[ -n "$RESERVER_PID" ]]; then
  kill "$RESERVER_PID" >/dev/null 2>&1 || true
  wait "$RESERVER_PID" >/dev/null 2>&1 || true
  RESERVER_PID=""
fi

if [[ -n "$AGENT_PID" ]]; then
  kill "$AGENT_PID" >/dev/null 2>&1 || true
  wait "$AGENT_PID" >/dev/null 2>&1 || true
  AGENT_PID=""
fi
if grep -Fq 'initial' "$AGENT_LOG" && grep -Fq 'exec' "$AGENT_LOG"; then
  pass "host SSH agent observed initial and exec connections"
else
  fail "host SSH agent observed initial and exec connections"
fi

rm -f "$HOST_PUBLISHED" "$HOST_VOLUME_PUBLISHED" "$HOST_ROLLBACK" "$HOST_AGENT"
rmdir "$HOST_SOCKET_DIR" >/dev/null 2>&1 || true

list_krun_runtime_dirs >"$RESULT_DIR/final-runtime-dirs.txt"
comm -13 "$RESULT_DIR/initial-runtime-dirs.txt" "$RESULT_DIR/final-runtime-dirs.txt" \
  >"$RESULT_DIR/new-runtime-dirs.txt"
if [[ ! -s "$RESULT_DIR/new-runtime-dirs.txt" ]]; then
  pass "Unix socket validation left no new krun runtime socket directories"
else
  fail "Unix socket validation left new krun runtime socket directories"
fi

finish_validation
trap - EXIT INT TERM
if ((FAILURES > 0)); then
  exit 1
fi
exit 0
