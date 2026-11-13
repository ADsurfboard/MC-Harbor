#!/usr/bin/env python3
"""Native dependency/path regression, using only isolated temporary fixtures."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='harbor-metadata-regression-') as directory:
    executable=Path(directory)/'metadata-tests'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fmodules','-Wall','-Werror','-framework','Foundation',
                    '-I',str(root/'Native'),str(root/'Native/HarborModpackMetadata.m'),
                    str(root/'Tests/HarborModpackMetadataTests.m'),'-o',str(executable)],check=True,timeout=60)
    subprocess.run([str(executable)],check=True,timeout=20)
