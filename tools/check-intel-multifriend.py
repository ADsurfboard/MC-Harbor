"""Exercise 24 synthetic friends with the production x86 Swift client on loopback."""
from pathlib import Path
import json,os,shutil,subprocess,sys,tempfile

root=Path(__file__).resolve().parent.parent
evidence=root/'evidence';evidence.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='intel-multifriend-',dir=evidence) as temporary:
    folder=Path(temporary);fixture=folder/'server';client=folder/'client';client.mkdir()
    environment=dict(os.environ,HARBOR_QA_FIXTURE_DIR=str(fixture))
    server=subprocess.Popen([sys.executable,str(root/'tools/prepare-friends-qa.py')],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        line=server.stdout.readline()
        if not line:raise RuntimeError('Could not start the disposable friend service: '+server.stderr.read()[:500])
        info=json.loads(line);assert info['fixtureOnly'] and info['friends']==24
        values=json.loads((fixture/'identity.json').read_text())
        config=folder/'client.json';config.write_text(json.dumps({'multi':True,'url':info['url'],'token':values['identities'][0]['token']}));config.chmod(0o600)
        environment['SHENGGAN_BACKEND_RESOURCES']=str(root/'build/MC Harbor.app/Contents/Resources')
        test=subprocess.run([str(root/'build/update-checks'),str(config),str(client),str(root/'Assets')],env=environment,text=True,capture_output=True,timeout=300)
        print(test.stdout,end='')
        if test.returncode:
            print(test.stderr);raise SystemExit(test.returncode)
        report=json.loads((folder/'multi-native-report.json').read_text())
        assert report['failed']==0 and report['fixtureFriends']==24
        (evidence/'intel-multifriend-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
        print('Intel Swift client:',report['passed'],'multi-friend checks passed')
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
