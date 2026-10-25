"""Boot only the isolated vanilla QA client, then terminate that exact child after renderer startup."""
from pathlib import Path
import importlib.util,json,os,signal,subprocess,threading,time

spec=importlib.util.spec_from_file_location('engine',Path(__file__).with_name('check-engine.py'));engine=importlib.util.module_from_spec(spec);spec.loader.exec_module(engine)
run=engine.QA/'versions'/'Harbor-QA-1.20.1'
(run/'options.txt').write_text('soundCategory_master:0.0\nfullscreen:false\nmaxFps:30\n')
request={'command':'launch','root':str(engine.QA),'id':'Harbor-QA-1.20.1','runDirectory':str(run),'memory':1024,'gameJava':'/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java','username':'HarborQA','accountType':'offline','threads':8,'width':854,'height':480}
output=[];child=None;stopped=False
with (engine.EVIDENCE/'engine-launch.stderr').open('w') as err:
    process=subprocess.Popen(engine.BASE,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True)
    process.stdin.write(json.dumps(request)+'\n');process.stdin.close()
    def stop_exact_child():
        global stopped
        if child is not None:
            try:os.kill(child,signal.SIGTERM);stopped=True
            except ProcessLookupError:pass
    deadline=threading.Timer(90,process.terminate);deadline.start()
    try:
        for line in process.stdout:
            event=json.loads(line);output.append(event)
            if event.get('event')=='launched':child=event['pid'];threading.Timer(65,stop_exact_child).start();print('Isolated client launched; pid',child,flush=True)
            elif event.get('event')=='error':print('Launch error:',event.get('message'),flush=True)
        code=process.wait()
    finally:deadline.cancel();stop_exact_child()
logs=sorted((engine.DATA/'logs').glob('game-*.log'),key=lambda p:p.stat().st_mtime)
text=logs[-1].read_text(errors='replace') if logs else ''
result={'bridgeExit':code,'launched':child is not None,'stoppedByQA':stopped,'lwjglInitialized':'LWJGL' in text,'audioInitialized':'OpenAL initialized' in text,'rendererCreated':('main render target' in text or 'Created: ' in text),'log':str(logs[-1]) if logs else None,'events':output}
(engine.EVIDENCE/'engine-launch-report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in result.items() if k not in ['events','log']},ensure_ascii=False),flush=True)
if not result['launched'] or not result['rendererCreated']:raise SystemExit(1)
