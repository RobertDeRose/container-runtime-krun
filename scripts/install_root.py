#!/usr/bin/env python3
import os
import shutil
from pathlib import Path

binary = shutil.which("container")
if not binary:
    raise SystemExit(1)
resolved = Path(os.path.realpath(binary))
# Apple Container's Unix installation layout is <install-root>/bin/container.
if resolved.parent.name != "bin":
    raise SystemExit(1)
print(resolved.parent.parent)
