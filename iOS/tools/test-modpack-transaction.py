#!/usr/bin/env python3
"""Exercise production import transactions with real isolated files and async transports."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='harbor-transaction-build-') as directory:
    executable=Path(directory)/'transaction-tests'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fmodules','-fblocks','-Wall','-Werror','-framework','Foundation',
                    '-I',str(root/'Native'),str(root/'Native/HarborModpackMetadata.m'),
                    str(root/'Native/HarborModpackTransaction.m'),str(root/'Tests/HarborModpackTransactionTests.m'),
                    '-o',str(executable)],check=True,timeout=60)
    subprocess.run([str(executable)],check=True,timeout=30)
