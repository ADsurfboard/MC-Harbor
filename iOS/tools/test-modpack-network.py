#!/usr/bin/env python3
"""Download one small, real Modrinth file through the production native transport.

This explicit online check complements deterministic regression tests; it never
uses a Minecraft account or installs a mod into a player's instance.
"""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, tempfile, time, urllib.parse, urllib.request

parser=argparse.ArgumentParser()
parser.add_argument('--evidence',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
query=urllib.parse.urlencode({'loaders':json.dumps(['fabric']), 'game_versions':json.dumps(['1.20.1'])})
request=urllib.request.Request('https://api.modrinth.com/v2/project/ferrite-core/version?'+query,
    headers={'User-Agent':'MC-Harbor/0.1 (+https://github.com/ADsurfboard/MC-Harbor)'})
started=time.time()
report={'passed':False,'kind':'production-native-https-download','playerDataUsed':False,
        'chinaDirectNetworkVerified':False}
try:
    with urllib.request.urlopen(request,timeout=30) as response:
        versions=json.load(response)
    version=next(v for v in versions if any(0<f.get('size',0)<=8*1024*1024 for f in v['files']))
    files=sorted(version['files'],key=lambda f:not f.get('primary'))
    selected=next(f for f in files if 0<f.get('size',0)<=8*1024*1024)
    manifest={'path':'mods/'+selected['filename'], 'fileSize':selected['size'],
              'downloads':[selected['url']], 'hashes':selected['hashes']}
    assert urllib.parse.urlparse(selected['url']).hostname=='cdn.modrinth.com'
    report.update(project='ferrite-core',version=version['version_number'],file=selected['filename'],
                  expectedBytes=selected['size'],source=selected['url'])
    with tempfile.TemporaryDirectory(prefix='harbor-native-online-') as directory:
        temp=Path(directory);executable=temp/'network-test';destination=temp/'installed'
        manifest_path=temp/'manifest.json';manifest_path.write_text(json.dumps(manifest))
        subprocess.run(['xcrun','clang','-fobjc-arc','-fmodules','-fblocks','-Wall','-Werror','-framework','Foundation',
            '-I',str(root/'Native'),str(root/'Native/HarborModpackMetadata.m'),str(root/'Native/HarborModpackTransaction.m'),
            str(root/'Tests/HarborModpackNetworkTests.m'),'-o',str(executable)],check=True,timeout=60)
        subprocess.run([str(executable),str(manifest_path),str(destination)],check=True,timeout=135)
        downloaded=destination/manifest['path']
        assert downloaded.stat().st_size==selected['size']
        assert hashlib.sha512(downloaded.read_bytes()).hexdigest()==selected['hashes']['sha512']
        assert not list(temp.glob('.import-*'))
    report['passed']=True
finally:
    report['elapsedSeconds']=round(time.time()-started,2)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True,exist_ok=True)
        args.evidence.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False))
