#!/usr/bin/env python3
"""Compile the production token store with fake Security calls, no real secrets."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='harbor-token-regression-') as directory:
    executable = Path(directory) / 'token-tests'
    command = ['xcrun', 'clang', '-fobjc-arc', '-fmodules', '-Wall', '-Werror',
               '-Wno-unused-variable', '-framework', 'Foundation', '-framework', 'Security',
               '-I', str(root / 'Native'),
               '-DSecItemCopyMatching=HBRTestCopyMatching', '-DSecItemUpdate=HBRTestUpdate',
               '-DSecItemAdd=HBRTestAdd', '-DSecItemDelete=HBRTestDelete',
               str(root / 'Native/HarborAccountTokenStore.m'),
               str(root / 'Tests/HarborAccountTokenStoreTests.m'), '-o', str(executable)]
    subprocess.run(command, check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=20)
