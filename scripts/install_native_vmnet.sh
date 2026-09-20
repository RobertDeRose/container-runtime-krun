#!/usr/bin/env bash
# Run as the login user. Only the final trusted installation requests sudo.
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(id -u)" -ne 0 ]] || {
  echo "Run as the unprivileged Apple Container user on macOS; installation requests sudo." >&2; exit 1;
}
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 26 ]] || { echo "native vmnet requires macOS 26 or newer" >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="$root/.build-deps/libkrun"
[[ -f "$source_dir/include/libkrun.h" ]] || {
  echo "managed libkrun checkout is missing: $source_dir" >&2
  exit 1
}
install_root="${INSTALL_ROOT:-$(python3 "$root/scripts/install_root.py")}"
[[ -n "$install_root" ]] || { echo "Set INSTALL_ROOT to the installed Apple Container prefix" >&2; exit 1; }
plugin_dir="$install_root/libexec/container-plugins/container-runtime-krun"
trusted="/Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun"
sudoers="/etc/sudoers.d/container-runtime-krun-native-vmnet"
user="$(id -un)"
case "$user" in ''|*[!A-Za-z0-9._-]*) echo "unsupported sudoers user name: $user" >&2; exit 1;; esac
build="$root/.build/arm64-apple-macosx/release"
dylib="$source_dir/target/release/libkrun.1.19.4.dylib"
provenance="$source_dir/target/release/native-vmnet.provenance"
source_status() {
  git -C "$source_dir" status --porcelain=v1 --untracked-files=all -- . ':(exclude).checkout-*'
}
[[ -f "$provenance" && -z "$(source_status)" ]] || {
  echo "Run mise run libkrun with a committed patch in .build-deps/libkrun first" >&2
  source_status >&2
  exit 1
}
recorded_commit="$(awk -F= '$1=="commit" {print $2}' "$provenance")"
recorded_sha="$(awk -F= '$1=="source_build_sha256" {print $2}' "$provenance")"
[[ "$recorded_commit" == "$(git -C "$source_dir" rev-parse HEAD)" && "$recorded_sha" == "$(shasum -a 256 "$dylib" | awk '{print $1}')" ]] || {
  echo "libkrun checkout/build changed after provenance capture; rebuild first" >&2; exit 1;
}
mkdir -p "$plugin_dir/bin" "$plugin_dir/lib" "$plugin_dir/share/licenses/libkrun"
stage="$(mktemp -d "$plugin_dir/.native-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$build/container-runtime-krun" "$stage/container-runtime-krun"
cp "$build/container-krun-vmm-helper" "$stage/container-krun-vmm-helper"
cp "$dylib" "$stage/libkrun.dylib"
python3 "$root/scripts/macho_trust.py" --normalize "$stage/container-krun-vmm-helper" "$stage/libkrun.dylib"
codesign --force --sign - --timestamp=none "$stage/libkrun.dylib"
codesign --force --sign - --timestamp=none --entitlements "$root/signing/hypervisor.entitlements" "$stage/container-krun-vmm-helper"
codesign --verify --strict "$stage/container-krun-vmm-helper"
codesign --verify --strict "$stage/libkrun.dylib"
cp "$provenance" "$stage/libkrun.provenance"
{
  echo "backend=libkrun-vmnet-shared"
  echo "sha256=$(shasum -a 256 "$stage/libkrun.dylib" | awk '{print $1}')"
  echo "helper_sha256=$(shasum -a 256 "$stage/container-krun-vmm-helper" | awk '{print $1}')"
  echo "runtime_sha256=$(shasum -a 256 "$stage/container-runtime-krun" | awk '{print $1}')"
} >>"$stage/libkrun.provenance"

# Refuse pre-existing untrusted ancestors before any privileged filesystem write.
PYTHONPATH="$root/scripts" python3 - "$trusted" "$trusted/bin" "$trusted/lib" /private/etc/sudoers.d /private/etc/sudoers.d/container-runtime-krun-native-vmnet <<'PY_GUARD'
from pathlib import Path
import sys
from macho_trust import check_privileged_path
for value in sys.argv[1:]:
    check_privileged_path(Path(value), allow_missing=True)
for value in (sys.argv[1] + "/bin/container-krun-vmm-helper", sys.argv[1] + "/lib/libkrun.dylib", sys.argv[1] + "/lib/libkrun.provenance", "/private/etc/sudoers.d/container-runtime-krun-native-vmnet"):
    path = Path(value)
    if path.exists() or path.is_symlink():
        check_privileged_path(path)
        if not path.is_file():
            raise SystemExit(f"refusing non-file installation target: {path}")
PY_GUARD
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 "$trusted" "$trusted/bin" "$trusted/lib"
/usr/bin/sudo /bin/chmod -N "$trusted" "$trusted/bin" "$trusted/lib"
root_stage="$(/usr/bin/sudo /usr/bin/mktemp -d "$trusted/.install.XXXXXXXX")"
trap '/usr/bin/sudo /bin/rm -rf "$root_stage"; rm -rf "$stage"' EXIT
for item in bin/container-krun-vmm-helper lib/libkrun.dylib lib/libkrun.provenance; do
  name="${item##*/}"
  mode=0644
  [[ "$item" != bin/* ]] || mode=0755
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m "$mode" "$stage/$name" "$root_stage/$name"
  /usr/bin/sudo /bin/chmod -N "$root_stage/$name"
  /usr/bin/sudo /bin/mv -f "$root_stage/$name" "$trusted/$item"
done
# Only this root-owned executable is authorized, never a development binary.
printf '%s ALL=(root) NOPASSWD: NOSETENV: %s/bin/container-krun-vmm-helper *\n' "$user" "$trusted" >"$stage/sudoers"
/usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /private/etc/sudoers.d
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0440 "$stage/sudoers" "$root_stage/sudoers"
/usr/bin/sudo /bin/chmod -N "$root_stage/sudoers"
/usr/bin/sudo /usr/sbin/visudo -cf "$root_stage/sudoers"
/usr/bin/sudo /bin/mv -f "$root_stage/sudoers" "$sudoers"

cp "$root/plugin/container-runtime-krun/config.toml" "$plugin_dir/config.toml"
cp "$source_dir/LICENSE" "$plugin_dir/share/licenses/libkrun/LICENSE"
mv -f "$stage/container-runtime-krun" "$plugin_dir/bin/container-runtime-krun"
mv -f "$stage/container-krun-vmm-helper" "$plugin_dir/bin/container-krun-vmm-helper"
mv -f "$stage/libkrun.dylib" "$plugin_dir/lib/libkrun.dylib"
mv -f "$stage/libkrun.provenance" "$plugin_dir/lib/libkrun.provenance"
echo "Installed native-only runtime: $plugin_dir"
echo "Privileged code: $trusted (root-owned helper and libkrun)"
echo "Sudo authorization: $sudoers (user $user)"
echo "Restart Apple Container: container system stop && container system start"
