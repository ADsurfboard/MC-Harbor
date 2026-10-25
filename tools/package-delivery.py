"""Create the local delivery and a strictly allowlisted corresponding-source ZIP."""
from pathlib import Path
import hashlib, json, shutil, subprocess, zipfile, sys

root=Path(__file__).resolve().parent.parent
version='1.5.0'
output=root.parents[1]/'outputs';output.mkdir(exist_ok=True)
app=root/'build/MC Harbor.app'
appzip=output/('MC-Harbor-'+version+'-macOS-arm64.zip')
if '--source-only' not in sys.argv:
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    # ditto merges directories and leaves removed resources behind. Always stage a fresh bundle.
    stage=root/'build/delivery-stage'
    if stage.exists():shutil.rmtree(stage)
    stage.mkdir()
    subprocess.run(['/usr/bin/ditto',str(app),str(stage/app.name)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage/app.name)],check=True)
    if (output/app.name).exists():shutil.rmtree(output/app.name) # Our generated App only; prior ZIPs remain.
    shutil.copy2(root.parents[1]/'outputs/MC-Harbor-启动器介绍.pdf',stage/'MC-Harbor-Introduction.pdf')
    (stage/'README-Install.txt').write_text('MC Harbor 1.5.0\n将 MC Harbor.app 放入应用程序文件夹。macOS 26+ / Apple Silicon。\n好友与聊天默认服务已内置，首次创建好友身份即可使用，无需自行搭服务器。\nSakura 需要自己的访问密钥与节点额度；陶瓦优先 P2P，其他启动器可搭配独立陶瓦客户端。\n阅读附带 PDF 与源码中的 docs/SERVICES.md 了解完整功能与服务边界。\n游戏与启动器账号数据不在此压缩包内。现有设置与数据沿用。\nGitHub: https://github.com/ADsurfboard/MC-Harbor\nIssues: https://github.com/ADsurfboard/MC-Harbor/issues/new/choose\n')
    appzip.unlink(missing_ok=True)
    subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc',str(stage),str(appzip)],check=True)
    (stage/app.name).rename(output/app.name)
    shutil.rmtree(stage)


revision='fbcc17472f08e877d60d6b715734e8054e9e61ee'
upstream=root.parent/'Harbor/upstream'
archive=root/'build/HMCL-3.16.4-source.tar.gz'
subprocess.run(['git','archive','--format=tar.gz','--prefix=HMCL/','--output='+str(archive),revision],cwd=upstream,check=True)
core=Path('/Applications/稳定版我的世界启动器.jar')
source=output/('MC-Harbor-'+version+'-source.zip')
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as bundle:
    def add(file,path):bundle.write(file,'MC-Harbor-source/'+path)
    for folder in ['Sources','backend','docs','social-server','social-cloud','Licenses','.github']:
        for file in sorted((root/folder).rglob('*')):
            if file.is_file() and file.suffix in ['.swift','.java','.md','.py','.mjs','.sql','.jsonc','.txt','.yml'] and not any(part in ['__pycache__','node_modules','.wrangler','data'] for part in file.parts):add(file,str(file.relative_to(root)))
    for file in sorted((root/'tools').iterdir()):
        if file.suffix in ['.py','.swift','.java'] and file.name!='make-sounds.py':add(file,'tools/'+file.name)
    add(root/'README.md','README.md')
    add(root/'BUILDING.md','BUILDING.md')
    for name in ['CONTRIBUTING.md','CONTRIBUTORS.md','.gitattributes','.gitignore']:add(root/name,name)
    add(root/'Assets/Services.json','Assets/Services.json')
    for folder in ['Loaders','Brand','SkinViewer','Skins','Localization']:
        for file in sorted((root/'Assets'/folder).rglob('*')):
            if file.is_file() and file.suffix in ['.png','.html','.js','.ts','.LICENSE','.json']:add(file,str(file.relative_to(root)))
    for name in ['welcome.mp3','welcome-male.mp3','welcome-female2.mp3','welcome-male2.mp3']:add(root/'Assets/Voice'/name,'Assets/Voice/'+name)
    for file in sorted(upstream.glob('LICENSE*')):add(file,'Licenses/'+file.name)
    add(core,'vendor/HMCLCore.jar')
    for file in sorted(Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar')):add(file,'vendor/javafx/'+file.name)
    add(archive,'upstream/'+archive.name)
    add(output/'MC-Harbor-启动器介绍.pdf','MC-Harbor-Introduction.pdf')
    bundle.writestr('MC-Harbor-source/SOURCE.json',json.dumps({'version':version,'hmclRevision':revision,'hmclCoreSHA256':hashlib.sha256(core.read_bytes()).hexdigest(),'skinRenderer':'skinview3d 3.4.2 (MIT); Three.js and skinview-utils licenses included','audio':'JDSherbert sound files and soundbank intentionally excluded; see README.md.'},indent=2))
with zipfile.ZipFile(source) as bundle:
    assert bundle.testzip() is None
    names=bundle.namelist()
    assert not any(name.endswith(('Interface.soundbank','accounts.json','preferences.json','migration.json')) or '/voice-assets/' in name or '/evidence/' in name or '/.wrangler/' in name or '/node_modules/' in name for name in names)
shutil.copy2(root/'Assets/Brand/Icon.png',output/'MC-Harbor-icon.png')
shutil.copy2(root/'Assets/Brand/Mark.png',output/'MC-Harbor-mark.png')
shutil.copy2(root/'docs/ICON_PROMPT.md',output/'图标提示词.md')
print('App ZIP bytes:',appzip.stat().st_size)
print('Source ZIP bytes:',source.stat().st_size)
print(output)
