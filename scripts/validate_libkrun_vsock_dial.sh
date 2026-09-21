#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "libkrun vsock dial validation requires Apple Silicon macOS" >&2
  exit 1
}

for command in brew git make nm rustc cargo sw_vers tar tee xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

libkrun="$root/.build-deps/libkrun"
[[ -d "$libkrun/.git" && -r "$libkrun/include/libkrun.h" ]] || {
  echo "managed libkrun checkout is missing: $libkrun" >&2
  exit 1
}
grep -q 'krun_vsock_connect(' "$libkrun/include/libkrun.h" || {
  echo "managed libkrun does not contain krun_vsock_connect(); apply the dial patch first" >&2
  exit 1
}
grep -q 'vsock-host-dial' "$libkrun/tests/test_cases/src/lib.rs" || {
  echo "managed libkrun does not contain the vsock-host-dial behavioral test; apply the test patch first" >&2
  exit 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_root="$root/validation-results"
run_name="libkrun-vsock-dial-$stamp-$$"
run_dir="$result_root/$run_name"
test_artifacts="$run_dir/test-artifacts"
archive="$result_root/container-runtime-krun-$run_name.tar.gz"
mkdir -p "$test_artifacts"

runtime_head="$(git rev-parse HEAD)"
libkrun_head="$(git -C "$libkrun" rev-parse HEAD)"

{
  echo "timestamp_utc=$stamp"
  echo "runtime_head=$runtime_head"
  echo "libkrun_head=$libkrun_head"
  echo "macos=$(sw_vers -productVersion)"
  echo "build=$(sw_vers -buildVersion)"
  echo "arch=$(uname -m)"
  echo "rustc=$(rustc --version)"
  echo "cargo=$(cargo --version)"
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version)"
} >"$run_dir/run.env"

git status --short >"$run_dir/runtime-git-status.txt"
git -C "$libkrun" status --short >"$run_dir/libkrun-git-status.txt"
git -C "$libkrun" log -5 --decorate --oneline >"$run_dir/libkrun-log.txt"

libkrun_dylib="$libkrun/target/release/libkrun.1.19.4.dylib"
if [[ ! -r "$libkrun_dylib" ]]; then
  echo "expected built libkrun is missing: $libkrun_dylib" | tee "$run_dir/preflight.txt" >&2
  echo "Run through the mise validation task so its libkrun dependency builds first." | tee -a "$run_dir/preflight.txt" >&2
  status=1
else
  if nm -gU "$libkrun_dylib" | tee "$run_dir/libkrun-symbols.txt" | grep -Eq '[[:space:]]_krun_vsock_connect$'; then
    echo "PASS: built libkrun exports krun_vsock_connect" | tee "$run_dir/preflight.txt"
    status=0
  else
    echo "FAIL: built libkrun does not export krun_vsock_connect" | tee "$run_dir/preflight.txt" >&2
    status=1
  fi
fi

if [[ "$status" -eq 0 ]]; then
  llvm_prefix="${LLVM_PREFIX:-$(brew --prefix llvm)}"
  lld_prefix="${LLD_PREFIX:-$(brew --prefix lld)}"
  sdkroot="$(xcrun --sdk macosx --show-sdk-path)"

  set +e
  PATH="$lld_prefix/bin:$llvm_prefix/bin:$PATH" \
    LIBCLANG_PATH="$llvm_prefix/lib" \
    MACOSX_DEPLOYMENT_TARGET=26.0 \
    SDKROOT="$sdkroot" \
    KRUN_TEST_BASE_DIR="$test_artifacts" \
    make -C "$libkrun" BLK=1 NET=1 test \
      TEST=vsock-host-dial TEST_FLAGS="--keep-all" \
      2>&1 | tee "$run_dir/test-output.txt"
  status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -eq 0 ]] && ! grep -q 'OK - 1/1 passed' "$run_dir/test-output.txt"; then
    echo "FAIL: test harness did not report exactly one passing vsock-host-dial test" \
      | tee -a "$run_dir/test-output.txt" >&2
    status=1
  fi
fi

if [[ "$status" -eq 0 ]]; then
  result=PASS
else
  result=FAIL
fi

{
  echo "result=$result"
  echo "exit_status=$status"
  echo "runtime_head=$runtime_head"
  echo "libkrun_head=$libkrun_head"
} >"$run_dir/SUMMARY.txt"

tar -czf "$archive" -C "$result_root" "$run_name"
printf 'result=%s\narchive=%s\n' "$result" "$archive"
exit "$status"
