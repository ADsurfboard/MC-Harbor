"""Download pinned official Intel runtime dependencies into the disposable build directory."""
from pathlib import Path
import hashlib, json, shutil, subprocess, sys, tarfile, urllib.parse, urllib.request, zipfile

if sys.version_info < (3,12):raise SystemExit('Python 3.12 or newer is required for safe archive extraction.')
root=Path(__file__).resolve().parent.parent
folder=root/'build/intel-deps';folder.mkdir(parents=True,exist_ok=True)
items=json.loads((root/'tools/intel-deps.lock.json').read_text())
assert {x['file'] for x in items}=={'temurin-jre-x64.tar.gz','javafx-base-21.0.8-mac.jar','javafx-graphics-21.0.8-mac.jar','javafx-controls-21.0.8-mac.jar'}
for item in items:
    url=urllib.parse.urlsplit(item['source'])
    assert url.scheme=='https' and url.hostname in {'github.com','repo.maven.apache.org'}
    target=folder/item['file'];partial=target.with_suffix(target.suffix+'.part')
    def valid(path):return path.is_file() and path.stat().st_size==item['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256']
    if not valid(target):
        request=urllib.request.Request(item['source'],headers={'User-Agent':'MC-Harbor-Intel-Builder/1.5'})
        try:
            with urllib.request.urlopen(request,timeout=180) as response,partial.open('wb') as output:
                total=0
                while block:=response.read(1024*1024):
                    total+=len(block)
                    if total>item['bytes']:raise ValueError('Download exceeded pinned size: '+item['file'])
                    output.write(block)
            if not valid(partial):raise ValueError('SHA256 mismatch: '+item['file'])
            partial.replace(target)
        finally:partial.unlink(missing_ok=True)
    if target.suffix=='.jar':
        with zipfile.ZipFile(target) as archive:
            assert archive.testzip() is None
            for name in archive.namelist():
                if name.endswith('.dylib'):assert archive.read(name)[:8]==bytes([207,250,237,254,7,0,0,1]),name
    print('Verified',item['file'],flush=True)

archive=folder/'temurin-jre-x64.tar.gz';destination=folder/'jre-extract'
digest=hashlib.sha256(archive.read_bytes()).hexdigest();marker=destination/'.archive-sha256'
if not marker.is_file() or marker.read_text()!=digest:
    staging=folder/'jre-extract-staging'
    if staging.exists():shutil.rmtree(staging)
    staging.mkdir()
    try:
        with tarfile.open(archive,'r:gz') as bundle:bundle.extractall(staging,filter='data')
        homes=list(staging.glob('*/Contents/Home'))
        assert len(homes)==1 and (homes[0]/'bin/java').is_file()
        if destination.exists():shutil.rmtree(destination)
        staging.rename(destination);marker.write_text(digest)
    finally:
        if staging.exists():shutil.rmtree(staging)
homes=list(destination.glob('*/Contents/Home'));assert len(homes)==1
java=homes[0]/'bin/java'
assert 'x86_64' in subprocess.check_output(['/usr/bin/lipo','-archs',str(java)],text=True).split()
print('Intel Java runtime:',homes[0])
