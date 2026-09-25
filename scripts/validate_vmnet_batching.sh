#!/usr/bin/env bash
set -uo pipefail

INSTALL=0
ITERATIONS=10
PAYLOAD_MIB=16
RUNTIME_A="container-runtime-linux"
RUNTIME_B="container-runtime-krun"
IMAGE="alpine:3.20"
NETWORK_IMAGE="python:3.13-alpine"
NETWORK="default"
SUBNET_A="10.250.60.0/24"
SUBNET_B="10.250.61.0/24"
DIAL_PORT=43210
RESULT_ROOT="validation-results"
TIMEOUT=180

usage() {
  cat <<'USAGE'
Usage: scripts/validate_vmnet_batching.sh [options]

Validate the managed libkrun vmnet batching change and collect focused paired
network measurements against Apple's default runtime.

Options:
  --install              Build/install this checkout and restart Apple Container.
  --iterations N         Samples per repeated network metric (default: 10).
  --payload-mib N        MiB transferred by each bulk sample (default: 16).
  --result-root DIR      Evidence root (default: validation-results).
  --runtime-a NAME       Baseline runtime (default: container-runtime-linux).
  --runtime-b NAME       Comparison runtime (default: container-runtime-krun).
  --image IMAGE          Lifecycle image (default: alpine:3.20).
  --network-image IMAGE  Network service image (default: python:3.13-alpine).
  --network NAME         Network for service endpoints (default: default).
  --subnet-a CIDR        First temporary multi-NIC subnet (default: 10.250.60.0/24).
  --subnet-b CIDR        Second temporary multi-NIC subnet (default: 10.250.61.0/24).
  --timeout N            Command timeout seconds (default: 180).
  -h, --help             Show help.
USAGE
}

while (($#)); do
  case "$1" in
    --install) INSTALL=1; shift ;;
    --iterations) ITERATIONS="${2:?missing iterations}"; shift 2 ;;
    --payload-mib) PAYLOAD_MIB="${2:?missing payload size}"; shift 2 ;;
    --result-root) RESULT_ROOT="${2:?missing result root}"; shift 2 ;;
    --runtime-a) RUNTIME_A="${2:?missing runtime}"; shift 2 ;;
    --runtime-b) RUNTIME_B="${2:?missing runtime}"; shift 2 ;;
    --image) IMAGE="${2:?missing image}"; shift 2 ;;
    --network-image) NETWORK_IMAGE="${2:?missing network image}"; shift 2 ;;
    --network) NETWORK="${2:?missing network}"; shift 2 ;;
    --subnet-a) SUBNET_A="${2:?missing subnet}"; shift 2 ;;
    --subnet-b) SUBNET_B="${2:?missing subnet}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?missing timeout}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "--iterations must be positive" >&2; exit 2; }
[[ "$PAYLOAD_MIB" =~ ^[1-9][0-9]*$ ]] || { echo "--payload-mib must be positive" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "--timeout must be positive" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
case "$RESULT_ROOT" in
  /*) ;;
  *) RESULT_ROOT="$ROOT/$RESULT_ROOT" ;;
esac

for command in container git mise python3 tar shasum; do
  command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }
done

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PREFIX="vb-$(printf '%s' "$STAMP" | tr '[:upper:]' '[:lower:]')-$$"
OUT="$RESULT_ROOT/vmnet-batching-${STAMP}-$$"
ARCHIVE="$RESULT_ROOT/container-runtime-krun-vmnet-batching-${STAMP}-$$.tar.gz"
SAMPLES="$OUT/samples.tsv"
mkdir -p "$OUT"
printf 'runtime\tmetric\titeration\tduration_ms\tstatus\n' >"$SAMPLES"
PASSES=0
FAILURES=0
FINISHED=0

pass() { PASSES=$((PASSES + 1)); printf 'PASS: %s\n' "$*" | tee -a "$OUT/results.txt"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL: %s\n' "$*" | tee -a "$OUT/results.txt" >&2; }

capture() {
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

require() {
  local name="$1" label="$2"
  shift 2
  if capture "$name" "$@"; then
    pass "$label"
    return 0
  fi
  fail "$label"
  return 1
}

summarize_samples() {
  python3 - "$SAMPLES" "$PAYLOAD_MIB" "$RUNTIME_A" "$RUNTIME_B" "$ITERATIONS" >"$OUT/performance-summary.txt" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

samples_path = Path(sys.argv[1])
payload_mib = int(sys.argv[2])
runtime_a = sys.argv[3]
runtime_b = sys.argv[4]
iterations = int(sys.argv[5])
rows = list(csv.DictReader(samples_path.open(encoding="utf-8"), delimiter="\t"))
by_metric = defaultdict(lambda: defaultdict(dict))
for row in rows:
    by_metric[row["metric"]][row["runtime"]][int(row["iteration"])] = (
        float(row["duration_ms"]), int(row["status"])
    )

bulk_metrics = (
    f"published_tcp_host_to_guest_{payload_mib}m",
    f"network_guest_to_host_{payload_mib}m",
)
other_metrics = ("published_tcp_rtt", "published_udp_rtt")
failed = False
for metric in (*bulk_metrics, *other_metrics):
    print(f"metric={metric}")
    for runtime in (runtime_a, runtime_b):
        values = by_metric[metric][runtime]
        good = [duration for duration, status in values.values() if status == 0]
        print(f"  {runtime}.samples={len(good)}/{iterations}")
        if len(good) != iterations:
            failed = True
            continue
        median = statistics.median(good)
        print(f"  {runtime}.median_ms={median:.3f}")
        if metric in bulk_metrics:
            print(f"  {runtime}.median_mib_s={payload_mib * 1000.0 / median:.2f}")
    paired = []
    a = by_metric[metric][runtime_a]
    b = by_metric[metric][runtime_b]
    for i in range(1, iterations + 1):
        if i in a and i in b and a[i][1] == 0 and b[i][1] == 0 and a[i][0] > 0:
            paired.append(b[i][0] / a[i][0])
    if len(paired) == iterations:
        print(f"  paired_krun_over_linux_median={statistics.median(paired):.4f}")
    else:
        failed = True
    print()

raise SystemExit(1 if failed else 0)
PY
}

finish() {
  ((FINISHED == 0)) || return
  FINISHED=1
  local install_root plugin_dir
  install_root="$(python3 scripts/install_root.py 2>/dev/null || true)"
  plugin_dir="$install_root/libexec/container-plugins/container-runtime-krun"

  container system status --format json >"$OUT/system-status-final.json" 2>&1 || true
  container system logs --debug --last 15m >"$OUT/system-logs-final.txt" 2>&1 || true
  container list --all >"$OUT/container-list-final.txt" 2>&1 || true
  git status --short --branch >"$OUT/runtime-git-status.txt" 2>&1 || true
  git -C .build-deps/libkrun status --short --branch >"$OUT/libkrun-git-status.txt" 2>&1 || true

  if [[ -r "$plugin_dir/lib/libkrun.provenance" ]]; then
    cp "$plugin_dir/lib/libkrun.provenance" "$OUT/installed-libkrun.provenance"
  fi
  if [[ -r "$plugin_dir/lib/libkrun.dylib" ]]; then
    shasum -a 256 "$plugin_dir/lib/libkrun.dylib" >"$OUT/installed-libkrun.sha256" 2>&1 || true
  fi

  {
    echo "result=$([[ "$FAILURES" -eq 0 ]] && echo PASS || echo FAIL)"
    echo "passes=$PASSES"
    echo "failures=$FAILURES"
    echo "iterations=$ITERATIONS"
    echo "payload_mib=$PAYLOAD_MIB"
    echo "runtime_a=$RUNTIME_A"
    echo "runtime_b=$RUNTIME_B"
    echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
    echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
    echo "container_version=$(container --version 2>&1 || true)"
  } >"$OUT/SUMMARY.txt"

  tar -czf "$ARCHIVE" -C "$RESULT_ROOT" "$(basename "$OUT")"
  printf 'result=%s\n' "$([[ "$FAILURES" -eq 0 ]] && echo PASS || echo FAIL)"
  printf 'archive=%s\n' "$ARCHIVE"
}
trap finish EXIT INT TERM

{
  echo "timestamp_utc=$STAMP"
  echo "runtime_git_head=$(git rev-parse HEAD 2>/dev/null || true)"
  echo "libkrun_git_head=$(git -C .build-deps/libkrun rev-parse HEAD 2>/dev/null || true)"
  echo "container_version=$(container --version 2>&1 || true)"
  echo "iterations=$ITERATIONS"
  echo "payload_mib=$PAYLOAD_MIB"
} >"$OUT/environment.txt"

if ! require libkrun-diff-check "libkrun diff check" git -C .build-deps/libkrun diff --check; then
  exit 1
fi
if ! require libkrun-vmnet-bridge "libkrun native vmnet bridge tests" \
    .build-deps/libkrun/tests/vmnet_bridge/run.sh; then
  exit 1
fi

if ((INSTALL)); then
  require mise-check "runtime static checks" mise run check || exit 1
  require mise-test "runtime Swift tests" mise run test || exit 1
  require native-install "install patched runtime/libkrun" mise run native:install || exit 1
  require system-stop "stop Apple Container" container system stop || exit 1
  require system-start "start Apple Container" container system start || exit 1
fi

if capture native-vmnet-validation scripts/validate_native_vmnet.sh --output "$OUT/native-vmnet"; then
  pass "native vmnet behavioral validation"
else
  fail "native vmnet behavioral validation"
  exit 1
fi

if capture paired-network-benchmark \
    python3 scripts/benchmark_network_metrics.py \
      --samples "$SAMPLES" \
      --output "$OUT/network" \
      --prefix "$PREFIX" \
      --runtime-a "$RUNTIME_A" \
      --runtime-b "$RUNTIME_B" \
      --image "$IMAGE" \
      --network "$NETWORK" \
      --network-image "$NETWORK_IMAGE" \
      --payload-mib "$PAYLOAD_MIB" \
      --iterations "$ITERATIONS" \
      --subnet-a "$SUBNET_A" \
      --subnet-b "$SUBNET_B" \
      --dial-port "$DIAL_PORT" \
      --timeout "$TIMEOUT"; then
  pass "paired network behavioral/performance samples"
else
  fail "paired network behavioral/performance samples"
  exit 1
fi

if summarize_samples; then
  pass "bulk network sample completeness"
else
  fail "bulk network sample completeness"
  exit 1
fi

finish
exit "$([[ "$FAILURES" -eq 0 ]] && echo 0 || echo 1)"
