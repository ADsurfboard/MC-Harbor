"""Build an app soundbank from the officially downloaded JDSherbert free pack.

The original audio and the resulting bank must not be included in the public source archive.
The author's terms expressly allow packing audio into a soundbank shipped with a finished app.
"""
from pathlib import Path
import hashlib,json,struct,subprocess,tempfile,os

root=Path(__file__).resolve().parent.parent
source=Path(os.environ['JDS_WAV_DIR']) if os.environ.get('JDS_WAV_DIR') else next((root/'voice-assets/jds-ui-free').glob('*'))/'Stereo'/'wav (HD)'
mapping={'focus':'Cursor - 3','select':'Select - 1','navigate':'Cursor - 1','open':'Popup Open - 1','close':'Popup Close - 1','launch':'Swipe - 2','success':'Select - 2','error':'Error - 1','startup':'Popup Open - 1'}
entries={};blob=bytearray()
with tempfile.TemporaryDirectory(prefix='harbor-soundbank-') as stage:
    for cue,name in mapping.items():
        original=source/('JDSherbert - Ultimate UI SFX Pack - '+name+'.wav')
        target=Path(stage)/(cue+'.wav')
        subprocess.run(['ffmpeg','-v','error','-y','-i',str(original),'-af','silenceremove=start_periods=1:start_duration=0.002:start_threshold=-60dB:stop_periods=1:stop_duration=0.15:stop_threshold=-55dB','-ar','48000','-ac','2','-c:a','pcm_s16le',str(target)],check=True)
        data=target.read_bytes();entries[cue]={'offset':len(blob),'length':len(data)};blob.extend(data)
header=json.dumps({'author':'JDSherbert','pack':'Ultimate UI SFX Pack FREE','source':'https://jdsherbert.itch.io/ultimate-ui-sfx-pack','entries':entries},separators=(',',':')).encode()
output=root/'build/Interface.soundbank';output.write_bytes(b'MCHSFX01'+struct.pack('<I',len(header))+header+blob)
(root/'evidence').mkdir(exist_ok=True)
(root/'evidence/soundbank-report.json').write_text(json.dumps({'source':'https://jdsherbert.itch.io/ultimate-ui-sfx-pack','author':'JDSherbert','files':mapping,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'size':output.stat().st_size,'processing':'trim silence and PCM conversion only; no generated sound'},indent=2))
print('Built sourced stereo soundbank:',len(entries),'cues,',output.stat().st_size,'bytes')
