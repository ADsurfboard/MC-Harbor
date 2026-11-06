from pathlib import Path
import subprocess,os,zipfile
root=Path(__file__).resolve().parent.parent
jdk=Path(os.environ.get('JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home','-v','21'],text=True).strip())
jar=Path(os.environ.get('HMCL_CORE_JAR',str(root/'vendor/HMCLCore.jar' if (root/'vendor/HMCLCore.jar').exists() else Path('/Applications/稳定版我的世界启动器.jar'))))
fxroot=Path(os.environ.get('HMCL_FX_DIR',str(root/'build/intel-deps')))
fx=list(fxroot.glob('javafx-*-21.0.8-mac.jar'))
if len(fx)!=3:raise SystemExit('Expected the three Intel OpenJFX 21.0.8 JARs. Run tools/setup-intel-deps.py.')
classes=root/'build/backend-classes';classes.mkdir(parents=True,exist_ok=True)
sources=list((root/'backend').rglob('*.java'))
subprocess.run([str(jdk/'bin/javac'),'--release','17','-encoding','UTF-8','-cp',os.pathsep.join(map(str,[jar]+fx)),'-d',str(classes)]+list(map(str,sources)),check=True)
with zipfile.ZipFile(root/'build/Backend.jar','w',zipfile.ZIP_DEFLATED) as out:
 for p in classes.rglob('*.class'):out.write(p,str(p.relative_to(classes)))
print('Backend compiled')
