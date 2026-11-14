"""Exercise the complete production wallpaper panel in an isolated app model."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
(root / 'evidence').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='harbor-wallpaper-library-') as directory:
    temporary = Path(directory)
    client = temporary / 'client'; client.mkdir()
    config = temporary / 'config.json'
    config.write_text(json.dumps({'wallpaperUI': True,
        'video': str(root / 'tests/fixtures/wallpaper.mp4'),
        'image': str(root / 'Assets/Skins/wide/steve.png')}))
    environment = os.environ.copy()
    environment.update(SHENGGAN_SKIP_INTRO='1', HARBOR_SKIP_LIVE_QA='1',
        SHENGGAN_BACKEND_RESOURCES=str(root / 'build/MC Harbor.app/Contents/Resources'))
    try:
        subprocess.run([str(root / 'build/update-checks'), str(config), str(client), str(root / 'Assets')],
                       env=environment, check=True, timeout=90)
    finally:
        report = temporary / 'wallpaper-library-report.json'
        if report.exists(): shutil.copy2(report, root / 'evidence/wallpaper-library-report.json')
