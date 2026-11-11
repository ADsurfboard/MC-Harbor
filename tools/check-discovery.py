from pathlib import Path
import json,os,subprocess,tempfile
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='mcharbor-discovery-') as t:
    folder=Path(t);config=folder/'config.json'
    config.write_text(json.dumps({'discovery':True,'live':os.environ.get('HARBOR_LIVE_DISCOVERY')=='1'}))
    env=dict(os.environ,SHENGGAN_BACKEND_RESOURCES=str(root/'build/MC Harbor.app/Contents/Resources'))
    subprocess.run([str(root/'build/update-checks'),str(config),str(folder/'data'),str(root/'Assets')],env=env,check=True,timeout=360)
