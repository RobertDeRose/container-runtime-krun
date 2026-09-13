#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 RESULT_DIR" >&2
  exit 2
fi

RESULT_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

for command in otool python3 shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

install_root="${INSTALL_ROOT:-$(python3 "$PROJECT_ROOT/scripts/install_root.py" 2>/dev/null || true)}"
[[ -n "$install_root" ]] || {
  echo "unable to derive Apple Container installation root" >&2
  exit 1
}

plugin_dir="$install_root/libexec/container-plugins/container-runtime-krun"
provenance="$plugin_dir/lib/libkrun.provenance"
dylib="$plugin_dir/lib/libkrun.dylib"

[[ -r "$provenance" ]] || {
  echo "installed libkrun provenance not found: $provenance" >&2
  exit 1
}
[[ -r "$dylib" ]] || {
  echo "installed libkrun dylib not found: $dylib" >&2
  exit 1
}

mkdir -p "$RESULT_DIR"
cp "$provenance" "$RESULT_DIR/libkrun.provenance"

provenance_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$provenance"
}

for key in repository commit upstream_base version features sha256; do
  [[ -n "$(provenance_value "$key")" ]] || {
    echo "installed libkrun provenance is missing $key" >&2
    exit 1
  }
done

recorded_sha="$(provenance_value sha256)"
actual_sha="$(shasum -a 256 "$dylib" | awk '{print $1}')"

{
  echo "path=$dylib"
  echo "sha256=$actual_sha"
  echo "provenance_sha256=$recorded_sha"
} >"$RESULT_DIR/libkrun-dylib.txt"
otool -L "$dylib" >"$RESULT_DIR/libkrun-otool.txt"

if [[ "$actual_sha" != "$recorded_sha" ]]; then
  echo "installed libkrun SHA-256 does not match package provenance" >&2
  exit 1
fi

if tail -n +2 "$RESULT_DIR/libkrun-otool.txt" | grep -Eq '(/opt/homebrew|/usr/local/(Cellar|opt))'; then
  echo "installed libkrun has a Homebrew runtime dependency" >&2
  exit 1
fi

cat "$RESULT_DIR/libkrun.provenance"
echo "installed_path=$dylib"
echo "installed_sha256=$actual_sha"
