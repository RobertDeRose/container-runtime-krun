#!/usr/bin/env python3
"""Audit the dynamic-loader inputs of code used before the native vmnet UID drop."""
from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import re
import subprocess


LOADS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}


def parse_load_commands(text: str) -> tuple[list[str], list[str]]:
    libraries: list[str] = []
    rpaths: list[str] = []
    command = ""
    for line in text.splitlines():
        match = re.fullmatch(r"\s*cmd (LC_\w+)\s*", line)
        if match:
            command = match[1]
            if command == "LC_DYLD_ENVIRONMENT":
                raise ValueError("embedded dyld environment is not permitted in privileged code")
        elif command in LOADS:
            match = re.fullmatch(r"\s*name (.+) \(offset \d+\)\s*", line)
            if match:
                libraries.append(match[1])
        elif command == "LC_RPATH":
            match = re.fullmatch(r"\s*path (.+) \(offset \d+\)\s*", line)
            if match:
                rpaths.append(match[1])
    if not libraries:
        raise ValueError("no Mach-O dependent libraries found")
    return libraries, rpaths


def trusted_system_library(name: str) -> bool:
    return ".." not in PurePosixPath(name).parts and name.startswith(("/usr/lib/", "/System/Library/"))


def normalize(path: Path) -> None:
    libraries, rpaths = inspect(path)
    for library in sorted(set(libraries)):
        if re.fullmatch(r"@rpath/libswift[A-Za-z0-9_]+\.dylib", library):
            # Native vmnet requires macOS 26+. Use its system Swift libraries,
            # never a compiler toolchain in a writable developer directory.
            replacement = "/usr/lib/swift/" + library.removeprefix("@rpath/")
            subprocess.run(["/usr/bin/install_name_tool", "-change", library, replacement, str(path)], check=True)
        elif not trusted_system_library(library):
            raise ValueError(f"non-system privileged dependency: {library}")
    for rpath in sorted(set(rpaths)):
        subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", rpath, str(path)], check=True)
    audit(path)


def inspect(path: Path) -> tuple[list[str], list[str]]:
    result = subprocess.run(["/usr/bin/otool", "-l", str(path)], check=True, text=True, capture_output=True)
    return parse_load_commands(result.stdout)


def audit(path: Path) -> None:
    libraries, rpaths = inspect(path)
    if rpaths:
        raise ValueError(f"privileged image has LC_RPATH entries: {rpaths}")
    for library in libraries:
        if not trusted_system_library(library):
            raise ValueError(f"non-system privileged dependency: {library}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--normalize", action="store_true", help="rewrite system Swift references and remove rpaths before signing")
    parser.add_argument("images", nargs="+", type=Path)
    args = parser.parse_args()
    for image in args.images:
        (normalize if args.normalize else audit)(image)
        print(f"PASS: privileged dynamic-loader closure {image}")



def check_privileged_path(path: Path, *, allow_missing: bool = False) -> None:
    """Reject symlinks, non-root ownership, writable modes, and ACL allow grants."""
    import os
    import stat

    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"privileged path must be absolute and normalized: {path}")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            info = current.lstat()
        except FileNotFoundError:
            if allow_missing:
                return  # Missing descendants will be created beneath a trusted parent.
            raise
        if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise ValueError(f"untrusted privileged path: {current}")
        if not (stat.S_ISDIR(info.st_mode) or (current == path and stat.S_ISREG(info.st_mode))):
            raise ValueError(f"unexpected file type in privileged path: {current}")
        if os.uname().sysname == "Darwin":
            result = subprocess.run(["/bin/ls", "-lde", str(current)], check=True,
                                    text=True, capture_output=True, timeout=5)
            for line in result.stdout.splitlines()[1:]:
                if not re.fullmatch(r"\s*\d+: .+ deny .+", line):
                    raise ValueError(f"ACL grant or unrecognized ACL on privileged path: {current}: {line}")


if __name__ == "__main__":
    main()
