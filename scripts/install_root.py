#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
from pathlib import Path


def derive_install_root() -> Path | None:
    binary = shutil.which("container")
    if not binary:
        return None
    resolved = Path(os.path.realpath(binary))
    # Apple Container's Unix installation layout is <install-root>/bin/container.
    if resolved.parent.name != "bin":
        return None
    return resolved.parent.parent


if __name__ == "__main__":
    root = derive_install_root()
    if root is None:
        raise SystemExit(1)
    print(root)
