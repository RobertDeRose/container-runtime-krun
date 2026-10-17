#!/usr/bin/env bash
# Build and run the host-only vmnet TX service-rate benchmark against the
# production bridge code in the managed libkrun checkout. Requests sudo for
# vmnet shared mode. Does not build, install, or restart anything.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source="$root/.build-deps/libkrun/src/libkrun/src/vmnet.c"
[[ -f "$source" ]] || { echo "managed libkrun checkout is missing: $source" >&2; exit 1; }
seconds="${SECONDS_PER_MODE:-10}"
frame="${FRAME_BYTES:-64800}"
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
out="$root/validation-results/vmnet-tx-bench-$stamp-$$"
mkdir -p "$out"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

sdk="$(xcrun --sdk macosx --show-sdk-path)"
clang -O2 -std=c11 -fblocks -Wall -Wextra -Wno-unused-parameter -isysroot "$sdk" \
  -DKRUN_VMNET_SOURCE="\"$source\"" \
  "$root/scripts/vmnet_tx_bench/vmnet_tx_bench.c" \
  -framework vmnet -framework CoreFoundation -lpthread \
  -o "$build/vmnet-tx-bench"

{
  echo "git_head=$(git -C "$root" rev-parse HEAD)"
  echo "libkrun_head=$(git -C "$root/.build-deps/libkrun" rev-parse HEAD)"
  echo "frame_bytes=$frame seconds_per_mode=$seconds"
  echo "host=$(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string)"
  uptime
} | tee "$out/environment.txt"

# Direct vmnet_write modes are not run by default: unpaced writes exhaust kernel
# mbuf clusters within about 1300 frames and block vmnet_write for 20-30 s,
# which is host-wide state. Run them by hand, paced: vmnet-tx-bench -d -q -T <writers> -r 40000 direct 1.
/usr/bin/sudo -v
for iteration in 1 2 3; do
  for mode in socket bridge; do
    /usr/bin/sudo "$build/vmnet-tx-bench" -l "$frame" -s "$seconds" "$mode" 2>&1 | tee -a "$out/results.txt"
  done
done
echo "output=$out"
