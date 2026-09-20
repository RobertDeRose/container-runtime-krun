#!/usr/bin/env bash
# Build the repository-managed libkrun checkout without fetching or resetting it.
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "native vmnet requires an Apple Silicon macOS shell" >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="$root/.build-deps/libkrun"
[[ -f "$source_dir/include/libkrun.h" ]] || {
  echo "managed libkrun checkout is missing: $source_dir" >&2
  echo "Populate .build-deps/libkrun using the repository dependency workflow first." >&2
  exit 1
}

source_status() {
  # .checkout-* is mise's own checkout stamp, not libkrun source state.
  git -C "$source_dir" status --porcelain=v1 --untracked-files=all -- . ':(exclude).checkout-*'
}

[[ -z "$(source_status)" ]] || {
  echo "Commit libkrun source changes before building so installed provenance identifies exact source." >&2
  source_status >&2
  exit 1
}
commit="$(git -C "$source_dir" rev-parse HEAD)"
grep -q 'krun_add_net_vmnet_shared(' "$source_dir/include/libkrun.h" || {
  echo "Apply the coordinated native vmnet libkrun patch first." >&2; exit 1;
}
sdk="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk%%.*}" -ge 26 ]] || { echo "macOS SDK 26 or newer is required (found $sdk)" >&2; exit 1; }
llvm_prefix="${LLVM_PREFIX:-$(brew --prefix llvm)}"
lld_prefix="${LLD_PREFIX:-$(brew --prefix lld)}"
[[ -r "$llvm_prefix/lib/libclang.dylib" && -x "$lld_prefix/bin/ld.lld" ]] || {
  echo "Homebrew llvm and lld are required" >&2; exit 1;
}
mkdir -p "$source_dir/target/release"
libclang_link="$source_dir/target/release/libclang.dylib"
[[ ! -e "$libclang_link" && ! -L "$libclang_link" ]] || {
  echo "Refusing to replace an existing $libclang_link" >&2; exit 1;
}
ln -s "$llvm_prefix/lib/libclang.dylib" "$libclang_link"
trap 'rm -f "$libclang_link"' EXIT
PATH="$lld_prefix/bin:$llvm_prefix/bin:$PATH" \
  LIBCLANG_PATH="$llvm_prefix/lib" \
  MACOSX_DEPLOYMENT_TARGET=26.0 SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  make -C "$source_dir" BLK=1 NET=1
rm -f "$libclang_link"
trap - EXIT
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$commit" && -z "$(source_status)" ]] || {
  echo "libkrun source changed during the build; refusing ambiguous provenance" >&2
  source_status >&2
  exit 1
}
dylib="$source_dir/target/release/libkrun.1.19.4.dylib"
[[ -r "$dylib" ]] || { echo "missing build output $dylib" >&2; exit 1; }
symbols="$(nm -gU "$dylib")"
for symbol in _krun_add_net_vmnet_shared _krun_create_ctx2 _krun_request_vmm_stop; do
  grep -Eq "[[:space:]]${symbol}$" <<<"$symbols" || { echo "missing native ABI symbol $symbol" >&2; exit 1; }
done
{
  echo "repository=$(git -C "$source_dir" remote get-url origin 2>/dev/null || echo local-checkout)"
  echo "commit=$commit"
  echo "upstream_base=728df8125077d0db44265f6e997c72b81b65c015"
  echo "version=1.19.4"
  echo "features=BLK=1 NET=1"
  echo "source_dirty=false"
  echo "source_path=$source_dir"
  echo "source_build_sha256=$(shasum -a 256 "$dylib" | awk '{print $1}')"
} >"$source_dir/target/release/native-vmnet.provenance"
echo "Built native libkrun from $commit (source checkout preserved)"
