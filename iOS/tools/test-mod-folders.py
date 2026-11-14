#!/usr/bin/env python3
"""Run real folder persistence/file operations with isolated storage fixtures."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="harbor-folder-runner-") as temporary:
    binary = Path(temporary) / "folders"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(root / "HarborCore/Sources/HarborCore/ModFolders.swift"),
                    str(root / "HarborCore/Sources/HarborCore/ModMetadata.swift"),
                    str(root / "Tests/HarborModFoldersChecks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=60)
