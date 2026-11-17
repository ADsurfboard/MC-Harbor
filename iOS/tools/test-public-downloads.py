#!/usr/bin/env python3
"""Actual Foundation sessions with isolated protocol fixtures, not a live CDN test."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
networking=root.parent/'vendor/AmethystIOS/Natives/external/AFNetworking/AFNetworking'
with tempfile.TemporaryDirectory(prefix='harbor-public-downloads-') as temporary:
    binary=Path(temporary)/'checks'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation','-I',str(root/'Native'),
        str(root/'Native/HarborPublicDownloads.m'),str(root/'Tests/HarborPublicDownloadsChecks.m'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=35)
    # The file transport runs on the engine's own pinned AFNetworking sources.
    transfer=Path(temporary)/'transfer-checks'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-w','-framework','Foundation','-framework','Security',
        '-framework','SystemConfiguration','-framework','CoreGraphics','-framework','AppKit',
        '-I',str(root/'Native'),'-I',str(networking),
        *[str(networking/name) for name in ('AFURLSessionManager.m','AFSecurityPolicy.m','AFURLResponseSerialization.m','AFNetworkReachabilityManager.m')],
        str(root/'Native/HarborPublicDownloads.m'),str(root/'Native/HarborPublicTransfer.m'),
        str(root/'Tests/HarborPublicTransferChecks.m'),'-o',str(transfer)],check=True)
    subprocess.run([str(transfer)],check=True,timeout=120)
