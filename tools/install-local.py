"""Atomic local update after the launcher was normally quit. Player data is never copied."""
from pathlib import Path
import os, plistlib, shutil, subprocess, time

root=Path(__file__).resolve().parent.parent
source=root/'build/MC Harbor.app';installed=Path('/Applications/MC Harbor.app');stage=Path('/Applications/.MC-Harbor-update.app')
if subprocess.run(['pgrep','-f','/Applications/MC [Hh]arbor.app/Contents/MacOS/MCHarbor'],capture_output=True).returncode==0:raise SystemExit('Quit the launcher normally before running this update.')
info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='net.morben.shenggan.launcher'
assert info['CFBundleDisplayName']=='MC Harbor'
assert (source/'Contents/Resources/welcome.mp3').read_bytes()==(root/'Assets/Voice/welcome.mp3').read_bytes()
assert not (source/'Contents/Resources/welcome.wav').exists()
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(source)],check=True)
if stage.exists():shutil.rmtree(stage)
subprocess.run(['/usr/bin/ditto',str(source),str(stage)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage)],check=True)
previous=None
if installed.exists():
    old=plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleVersion']
    previous=root/f'build/previous-installed-{old}-{time.time_ns()}.app';installed.rename(previous)
try:stage.rename(installed)
except Exception:
    if previous is not None:previous.rename(installed)
    raise
os.utime(installed,None)
subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(installed)],check=True,capture_output=True)
print('Installed',info['CFBundleDisplayName'],info['CFBundleShortVersionString'],'at',installed)
print('Existing settings, credentials and games retained; previous App retained for rollback.')
