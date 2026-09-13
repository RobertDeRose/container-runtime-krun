#!/usr/bin/env bash
set -uo pipefail

RUNTIME="container-runtime-krun"
IMAGE="alpine:3.20"
INSTALL=0
RESULT_ROOT="validation-results"
SUBNET_A="10.250.10.0/24"
SUBNET_B="10.250.11.0/24"

usage(){ cat <<'USAGE'
Usage: scripts/validate_multiple_networks.sh [options]

Create two temporary Apple allocationOnly networks and validate one krun
container attached to both. The first attachment remains primary for the
default route, DNS fallback, hostname identity, and published TCP ports.

Options:
  --install          Build/install this checkout and restart Apple Container.
  --runtime NAME     Runtime name (default: container-runtime-krun).
  --image IMAGE      Image (default: alpine:3.20).
  --subnet-a CIDR    First temporary network (default: 10.250.10.0/24).
  --subnet-b CIDR    Second temporary network (default: 10.250.11.0/24).
  --result-root DIR  Output directory (default: validation-results).
  -h, --help         Show help.
USAGE
}
while (($#)); do
  case "$1" in
    --install) INSTALL=1; shift;;
    --runtime) RUNTIME="${2:?missing runtime}"; shift 2;;
    --image) IMAGE="${2:?missing image}"; shift 2;;
    --subnet-a) SUBNET_A="${2:?missing subnet}"; shift 2;;
    --subnet-b) SUBNET_B="${2:?missing subnet}"; shift 2;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
for c in container mise git python3 ps; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
python3 - "$SUBNET_A" "$SUBNET_B" <<'PY'
import ipaddress, sys
a,b=map(ipaddress.ip_network, sys.argv[1:])
if a.version != 4 or b.version != 4 or a.overlaps(b): raise SystemExit("subnets must be distinct non-overlapping IPv4 networks")
PY

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="krun-multinet-${STAMP}-$$"
NET_PREFIX="kmn-$(date -u '+%Y%m%d%H%M%S')-$$"
NET_A="$NET_PREFIX-a"; NET_B="$NET_PREFIX-b"; ID="$PREFIX-live"
OUT="$RESULT_ROOT/multiple-networks-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-multiple-networks-${STAMP}-$$.tar.gz"
mkdir -p "$OUT"
FAILURES=0; PASSES=0
pass(){ PASSES=$((PASSES+1)); echo "PASS: $*" | tee -a "$OUT/results.txt"; }
fail(){ FAILURES=$((FAILURES+1)); echo "FAIL: $*" | tee -a "$OUT/results.txt" >&2; }
run(){ local n="$1"; shift; { printf '$'; printf ' %q' "$@"; printf '\n'; "$@"; local r=$?; printf '\nexit_status=%d\n' "$r"; return "$r"; } >"$OUT/$n.txt" 2>&1; }
free_port(){ python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}
gateway_for_cidr(){ python3 - "$1" <<'PY'
import ipaddress,sys
network=ipaddress.ip_network(sys.argv[1])
print(network.network_address + 1)
PY
}
wait_exec_ready(){
  local deadline=$((SECONDS+5))
  : >"$OUT/running-probe.txt"
  while ((SECONDS<deadline)); do
    if container exec "$ID" true >>"$OUT/running-probe.txt" 2>&1; then
      return 0
    fi
    sleep .2
  done
  return 1
}
find_helper_pids(){
  local gateway="$1"
  /bin/ps -axo pid=,command= | awk -v gateway="$gateway" '
    index($0, "vmnet-helper") && index($0, "--start-address " gateway) { print $1 }
  '
}
helper_is_running(){
  local pid="$1"
  /bin/ps -p "$pid" -o command= 2>/dev/null | grep -Fq 'vmnet-helper'
}
wait_helper_cleanup(){
  local first="$1" second="$2" deadline=$((SECONDS+12))
  while ((SECONDS<deadline)); do
    if ! helper_is_running "$first" && ! helper_is_running "$second"; then
      return 0
    fi
    sleep .2
  done
  return 1
}
capture_diagnostics(){
  local label="$1"
  local status_file="$OUT/system-status-${label}.json"
  container inspect "$ID" >"$OUT/container-inspect-${label}.txt" 2>&1 || true
  container logs "$ID" >"$OUT/container-logs-${label}.txt" 2>&1 || true
  /bin/ps -axo pid=,ppid=,etime=,rss=,command= >"$OUT/processes-${label}.txt" 2>&1 || true
  container system status --format json >"$status_file" 2>&1 || true
  container system logs --debug --last 5m >"$OUT/system-logs-${label}.txt" 2>&1 || true

  local app_root log_root bundle_root path
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
    for path in "$bundle_root"/krun-vmm.log "$bundle_root"/krun-vmnet-*.log \
      "$bundle_root"/vminitd.log "$bundle_root"/container.log "$bundle_root"/krun-vmm.json; do
      [[ -r "$path" ]] || continue
      cp "$path" "$OUT/${label}-$(basename "$path")"
    done
  fi
  if [[ -n "$log_root" && -r "$log_root/container-runtime-krun-$ID.log" ]]; then
    cp "$log_root/container-runtime-krun-$ID.log" "$OUT/runtime-plugin-${label}.log"
  fi
}
wait_network_release_logs(){
  local deadline=$((SECONDS+10)) log_file="$OUT/system-logs-after-delete.txt"
  while ((SECONDS<deadline)); do
    container system logs --debug --last 5m >"$log_file" 2>&1 || true
    if grep -F "$NET_A" "$log_file" | grep -Fq 'allocated attachment' \
      && grep -F "$NET_A" "$log_file" | grep -Fq 'released session' \
      && grep -F "$NET_B" "$log_file" | grep -Fq 'allocated attachment' \
      && grep -F "$NET_B" "$log_file" | grep -Fq 'released session'; then
      grep -E 'allocated attachment|released session' "$log_file" \
        | grep -E "$NET_A|$NET_B" >"$OUT/network-lifecycle.txt" || true
      return 0
    fi
    sleep .25
  done
  grep -E 'allocated attachment|released session' "$log_file" \
    | grep -E "$NET_A|$NET_B" >"$OUT/network-lifecycle.txt" || true
  return 1
}
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
cleanup(){ container delete --force "$ID" >/dev/null 2>&1 || true; container network delete "$NET_A" "$NET_B" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

{
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "runtime=$RUNTIME"
  echo "image=$IMAGE"
  echo "subnet_a=$SUBNET_A"
  echo "subnet_b=$SUBNET_B"
} >"$OUT/environment.txt"

if ((INSTALL)); then
  require_run mise_doctor "mise run doctor" mise run doctor
  require_run mise_check "mise run check" mise run check
  require_run mise_test "mise run test" mise run test
  require_run mise_install "mise run install" mise run install
  require_run system_stop "container system stop" container system stop
  require_run system_start "container system start" container system start
fi

require_run create_net_a "first allocationOnly network created" \
  container network create --subnet "$SUBNET_A" --option variant=allocationOnly "$NET_A"
require_run create_net_b "second allocationOnly network created" \
  container network create --subnet "$SUBNET_B" --option variant=allocationOnly "$NET_B"
container network inspect "$NET_A" >"$OUT/network-a.json" 2>&1 || true
container network inspect "$NET_B" >"$OUT/network-b.json" 2>&1 || true

HOST_PORT="$(free_port)"
require_run start "two-network container start accepted" \
  container run -d --name "$ID" --runtime "$RUNTIME" --network "$NET_A" --network "$NET_B" \
  --publish "127.0.0.1:${HOST_PORT}:8080/tcp" "$IMAGE" sh -c \
  'while :; do sleep 3600; done'

if wait_exec_ready; then
  pass "two-network container remains running"
else
  fail "two-network container remains running"
  capture_diagnostics start-failure
  cleanup
  archive_results
  trap - EXIT INT TERM
  exit 1
fi

GATEWAY_A="$(gateway_for_cidr "$SUBNET_A")"
GATEWAY_B="$(gateway_for_cidr "$SUBNET_B")"
find_helper_pids "$GATEWAY_A" >"$OUT/helper-a-pids.txt"
find_helper_pids "$GATEWAY_B" >"$OUT/helper-b-pids.txt"
HELPER_A_COUNT="$(wc -l <"$OUT/helper-a-pids.txt" | tr -d ' ')"
HELPER_B_COUNT="$(wc -l <"$OUT/helper-b-pids.txt" | tr -d ' ')"
HELPER_A_PID="$(cat "$OUT/helper-a-pids.txt")"
HELPER_B_PID="$(cat "$OUT/helper-b-pids.txt")"
if [[ "$HELPER_A_COUNT" == 1 && "$HELPER_B_COUNT" == 1 \
  && "$HELPER_A_PID" != "$HELPER_B_PID" ]]; then
  pass "one vmnet-helper is live per attachment"
else
  fail "one vmnet-helper is live per attachment"
fi

run guest_network container exec "$ID" sh -c 'ip -o -4 addr show; echo ---routes---; ip -4 route; echo ---resolver---; cat /etc/resolv.conf' \
  && pass "guest network state collected" || fail "guest network state collected"
if grep -Eq '[[:space:]]eth0[[:space:]]' "$OUT/guest_network.txt" && grep -Eq '[[:space:]]eth1[[:space:]]' "$OUT/guest_network.txt"; then
  pass "guest exposes eth0 and eth1"
else
  fail "guest exposes eth0 and eth1"
fi
python3 - "$SUBNET_A" "$SUBNET_B" "$OUT/guest_network.txt" >"$OUT/address-check.txt" 2>&1 <<'PY'
import ipaddress,re,sys
nets=[ipaddress.ip_network(sys.argv[1]), ipaddress.ip_network(sys.argv[2])]
text=open(sys.argv[3], encoding='utf-8', errors='replace').read()
for idx,net in enumerate(nets):
    m=re.search(rf'\beth{idx}\b.*?inet\s+([0-9.]+)/', text)
    if not m: raise SystemExit(f'missing eth{idx} IPv4 address')
    addr=ipaddress.ip_address(m.group(1))
    if addr not in net: raise SystemExit(f'eth{idx} {addr} not in {net}')
    print(f'eth{idx}={addr} subnet={net}')
PY
[[ $? -eq 0 ]] && pass "interface order matches requested networks" || fail "interface order matches requested networks"

run route_policy container exec "$ID" sh -c 'test "$(ip -4 route show default | wc -l | tr -d " ")" = 1; ip -4 route show default | grep -q "dev eth0"; ip -4 route show dev eth1 | grep -q "scope link"' \
  && pass "only eth0 owns the default route while eth1 keeps its connected route" || fail "primary/secondary route policy"
run outbound container exec "$ID" ping -c 1 -W 3 1.1.1.1 && pass "outbound connectivity uses the primary attachment" || fail "outbound connectivity uses the primary attachment"
run dns container exec "$ID" nslookup example.com && pass "DNS resolves with multiple attachments" || fail "DNS resolves with multiple attachments"
run prepare_http container exec "$ID" sh -c \
  'set -eu; if ! command -v httpd >/dev/null 2>&1; then apk add --no-cache busybox-extras >/tmp/apk-busybox-extras.log 2>&1; fi; mkdir -p /www; printf multi-network-ok >/www/index.html; httpd -p 8080 -h /www' \
  && pass "guest HTTP probe started" || fail "guest HTTP probe started"

python3 - "$HOST_PORT" >"$OUT/published-port.txt" 2>&1 <<'PY'
import socket,sys,time
port=int(sys.argv[1]); deadline=time.time()+10
while True:
    try:
        s=socket.create_connection(('127.0.0.1',port), timeout=1)
        s.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n')
        data=b''
        while True:
            chunk=s.recv(65536)
            if not chunk: break
            data+=chunk
        s.close()
        if b'multi-network-ok' not in data: raise SystemExit(f'unexpected response: {data!r}')
        print(data.decode('latin1')); break
    except OSError:
        if time.time() >= deadline: raise
        time.sleep(.2)
PY
[[ $? -eq 0 ]] && pass "published TCP port targets the primary attachment" || fail "published TCP port targets the primary attachment"

run stats container stats --no-stream --format json "$ID" && pass "network statistics collected" || fail "network statistics collected"
python3 - "$OUT/stats.txt" >"$OUT/stats-check.txt" 2>&1 <<'PY2'
import json,sys
text=open(sys.argv[1], encoding='utf-8', errors='replace').read()
start=text.find('{'); end=text.rfind('}')
if start < 0 or end < start: raise SystemExit('no JSON object found')
data=json.loads(text[start:end+1])
for key in ('networkRxBytes','networkTxBytes'):
    value=data.get(key)
    if value is None or int(value) <= 0: raise SystemExit(f'{key} not positive: {value!r}')
    print(f'{key}={value}')
PY2
[[ $? -eq 0 ]] && pass "aggregated network counters include live traffic" || fail "aggregated network counters include live traffic"

capture_diagnostics live
run stop container stop "$ID" && pass "two-network container stopped" || fail "two-network container stopped"
run delete container delete "$ID" && pass "two-network container deleted" || fail "two-network container deleted"
if [[ "$HELPER_A_COUNT" == 1 && "$HELPER_B_COUNT" == 1 ]] \
  && wait_helper_cleanup "$HELPER_A_PID" "$HELPER_B_PID"; then
  pass "both network helpers cleaned up"
else
  fail "both network helpers cleaned up"
fi
container network inspect "$NET_A" >"$OUT/network-a-after.txt" 2>&1 || true
container network inspect "$NET_B" >"$OUT/network-b-after.txt" 2>&1 || true
if wait_network_release_logs; then
  pass "Apple released both network allocations"
else
  fail "Apple released both network allocations"
fi
run delete_networks container network delete "$NET_A" "$NET_B" && pass "temporary networks deleted" || fail "temporary networks deleted"

archive_results
trap - EXIT INT TERM
((FAILURES==0))
