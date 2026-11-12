"""Exercise packaged x86 Java and the actual localization/backend implementation in a fresh fixture."""
from pathlib import Path
import json, os, subprocess, tempfile

root=Path(__file__).resolve().parent.parent
resources=root/'build/MC Harbor.app/Contents/Resources'
java=resources/'Runtime/bin/java'
jdk=Path(os.environ.get('JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home','-v','21'],text=True).strip())
fx=sorted((resources/'javafx').glob('javafx-*-21.0.8-mac-aarch64.jar'))
assert len(fx)==3 and java.is_file()
classpath=os.pathsep.join(map(str,[Path(os.environ.get('HARBOR_QA_BACKEND_JAR',str(resources/'Backend.jar'))),resources/'HMCLCore.jar',*fx]))
with tempfile.TemporaryDirectory(prefix='mc-harbor-intel-qa-',dir=root/'build') as temporary:
    path=Path(temporary);classes=path/'classes';classes.mkdir()
    subprocess.run([str(jdk/'bin/javac'),'--release','17','-encoding','UTF-8','-cp',classpath,'-d',str(classes),str(root/'tools/UpdateBackendChecks.java'),str(root/'tools/LocalizationBackendChecks.java')],check=True)
    process=subprocess.run([str(java),'-Djava.awt.headless=true','-Dshenggan.headless=true','-cp',str(classes)+os.pathsep+classpath,'net.morben.shenggan.UpdateBackendChecks',str(path/'data')],text=True,capture_output=True,timeout=120)
    print(process.stdout,end='')
    if process.returncode:
        print(process.stderr);raise SystemExit(process.returncode)
    report=json.loads((path/'update-backend-report.json').read_text())
    assert report['failed']==0 and report['passed']>=22
    evidence=root/'evidence';evidence.mkdir(exist_ok=True)
    (evidence/'apple-backend-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
    print('Packaged Apple JVM backend:',report['passed'],'checks passed')
