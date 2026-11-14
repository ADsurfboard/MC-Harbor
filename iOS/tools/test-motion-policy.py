#!/usr/bin/env python3
"""Compile the actual native policy; use only process-volatile preferences."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="harbor-motion-") as temporary:
    binary = Path(temporary) / "motion"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-framework", "Foundation", "-I", str(root / "Native"),
                    str(root / "Tests/HarborMotionTests.m"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
