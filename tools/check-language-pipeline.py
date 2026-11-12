"""The real Swift translation coordinator and packaged Java bridge, using disposable resources."""
from pathlib import Path
import json,os,subprocess,tempfile,shutil
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='mcharbor-language-pipeline-') as temp:
    folder=Path(temp);config=folder/'config.json';config.write_text(json.dumps({'languagePipeline':True,'live':os.environ.get('HARBOR_LIVE_LOCALIZATION')=='1'}))
    env=dict(os.environ,SHENGGAN_BACKEND_RESOURCES=str(root/'build/MC Harbor.app/Contents/Resources'))
    subprocess.run([str(root/'build/update-checks'),str(config),str(folder/'data'),str(root/'Assets')],env=env,check=True,timeout=360)
    (root/'evidence').mkdir(exist_ok=True);shutil.copy2(folder/'language-pipeline-report.json',root/'evidence'/('language-pipeline-live.json' if env.get('HARBOR_LIVE_LOCALIZATION')=='1' else 'language-pipeline-offline.json'))
