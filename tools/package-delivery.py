"""Package and verify the committed Intel preview without including player data."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = Path(os.environ.get('HARBOR_DELIVERY_DIR', ROOT / 'outputs')).resolve()
APP = ROOT / 'build/MC Harbor.app'
PDF = ROOT / 'MC-Harbor-Introduction.pdf'
VERSION = '1.5.1'
APP_ZIP = OUTPUT / f'MC-Harbor-{VERSION}-Intel-macOS12.zip'
SOURCE_ZIP = OUTPUT / f'MC-Harbor-{VERSION}-Intel-source.zip'
PDF_OUT = OUTPUT / 'MC-Harbor-Intel-Introduction.pdf'
SUMS = OUTPUT / f'SHA256SUMS-{VERSION}-intel.txt'


def command(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def tree_manifest(folder):
    result = {}
    for path in sorted(folder.rglob('*')):
        name = str(path.relative_to(folder))
        if path.is_symlink():
            result[name] = ['link', os.readlink(path)]
        elif path.is_file():
            result[name] = ['file', sha256(path)]
        elif path.is_dir():
            result[name] = ['directory']
    return result


dirty = command('git', 'status', '--porcelain', cwd=ROOT, capture_output=True, text=True).stdout
if dirty:
    raise SystemExit('Commit or remove all untracked changes before producing the corresponding source archive.\n' + dirty)
revision = command('git', 'rev-parse', 'HEAD', cwd=ROOT, capture_output=True, text=True).stdout.strip()
if not APP.is_dir() or not PDF.is_file():
    raise SystemExit('Build the Intel app and its introduction PDF first.')
command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP))
bank = APP / 'Contents/Resources/Interface.soundbank'
if not bank.is_file() or sha256(bank) != sha256(ROOT / 'build/Interface.soundbank'):
    raise SystemExit('The release must include the verified local soundbank.')
OUTPUT.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='mcharbor-intel-delivery-') as temporary:
    temp = Path(temporary)
    stage = temp / 'delivery'
    stage.mkdir()
    command('/usr/bin/ditto', str(APP), str(stage / APP.name))
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(stage / APP.name))
    shutil.copy2(PDF, stage / PDF_OUT.name)
    (stage / 'README-Install.txt').write_text('''MC Harbor 1.5.1 Intel 兼容预览

适用 Intel 芯片、macOS 12 或以上。此预览版尚未在 macOS 12—14 实机完成界面验收。
先阅读随包 PDF；备份既有游戏和启动器数据后，再将 MC Harbor.app 放入应用程序文件夹。
本包为临时签名，尚未经过 Apple 公证；下载后如被系统阻止，请在“系统设置→隐私与安全性”查看打开选项。
好友与聊天内置默认服务；第三方服务、免费额度和网络连接可能变化。Sakura Frp 需要自己的账号、访问密钥和节点额度。
旧系统可选择在线汉化回退，确认后才会向第三方发送待翻译文本；免费额度和实际可用性受服务方限制。
游戏、账号和存档数据不包含在安装包内。完整验证范围见源码的 docs/QA-INTEL.md。

项目：https://github.com/ADsurfboard/MC-Harbor/tree/codex/intel-compat
反馈：https://github.com/ADsurfboard/MC-Harbor/issues
''', encoding='utf-8')
    APP_ZIP.unlink(missing_ok=True)
    command('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', str(stage), str(APP_ZIP))
    extracted = temp / 'extracted'
    extracted.mkdir()
    command('/usr/bin/ditto', '-x', '-k', str(APP_ZIP), str(extracted))
    restored = extracted / APP.name
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(restored))
    if tree_manifest(APP) != tree_manifest(restored):
        raise SystemExit('The restored application differs from the verified build.')
    if sha256(extracted / PDF_OUT.name) != sha256(PDF):
        raise SystemExit('The PDF changed in the delivery ZIP.')

SOURCE_ZIP.unlink(missing_ok=True)
command('git', 'archive', '--format=zip', '--prefix=MC-Harbor-Intel-source/',
        '--output=' + str(SOURCE_ZIP), revision, cwd=ROOT)
with zipfile.ZipFile(SOURCE_ZIP) as archive:
    if archive.testzip() is not None:
        raise SystemExit('The source ZIP failed its integrity check.')
    names = archive.namelist()
    forbidden_files = ('Interface.soundbank', 'accounts.json', 'preferences.json', 'migration.json')
    forbidden_dirs = ('/voice-assets/', '/evidence/', '/.wrangler/', '/node_modules/', '/MCHarborData/')
    if any(name.endswith(forbidden_files) or any(part in name for part in forbidden_dirs) for name in names):
        raise SystemExit('Player data or a locally licensed soundbank appeared in the source ZIP.')
shutil.copy2(PDF, PDF_OUT)
files = [APP_ZIP, SOURCE_ZIP, PDF_OUT]
SUMS.write_text(''.join(f'{sha256(path)}  {path.name}\n' for path in files), encoding='utf-8')
report = {'commit': revision, 'files': {p.name: {'bytes': p.stat().st_size, 'sha256': sha256(p)} for p in files},
          'roundTripIdentical': True, 'strictSignature': True, 'sourceFromCommit': True}
evidence = ROOT / 'evidence'
evidence.mkdir(exist_ok=True)
(evidence / 'intel-delivery-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2, ensure_ascii=False))
