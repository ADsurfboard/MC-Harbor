"""Mount the production wallpaper preview, using disposable native UI only."""
from pathlib import Path
import os, platform, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
(root / 'evidence').mkdir(exist_ok=True)
target = os.environ.get('HARBOR_QA_TARGET', 'x86_64-apple-macos12.0' if platform.machine() == 'x86_64' else 'arm64-apple-macos26.0')
with tempfile.TemporaryDirectory(prefix='harbor-wallpaper-ui-') as directory:
    binary = Path(directory) / 'wallpaper-preview-checks'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-target', target,
                    str(root / 'Sources/WallpaperPreview.swift'), str(root / 'tools/WallpaperPreviewChecks.swift'),
                    '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary), str(root / 'tests/fixtures/wallpaper.mp4'),
                    str(Path(directory) / 'missing.mp4'),
                    str(root / 'evidence/wallpaper-preview-report.json')], check=True, timeout=45)
