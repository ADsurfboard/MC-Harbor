from pathlib import Path
import subprocess,os,zipfile,tarfile,tempfile
root=Path(__file__).resolve().parent.parent
jdk=Path(os.environ.get('JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home','-v','21'],text=True).strip())
jar=Path(os.environ.get('HMCL_CORE_JAR',str(root/'vendor/HMCLCore.jar' if (root/'vendor/HMCLCore.jar').exists() else Path('/Applications/稳定版我的世界启动器.jar'))))
fxroot=Path(os.environ.get('HMCL_FX_DIR',str(root/'build/intel-deps')))
fx=list(fxroot.glob('javafx-*-21.0.8-mac.jar'))
if len(fx)!=3:raise SystemExit('Expected the three Intel OpenJFX 21.0.8 JARs. Run tools/setup-intel-deps.py.')
classes=root/'build/backend-classes';classes.mkdir(parents=True,exist_ok=True)
sources=list((root/'backend').rglob('*.java'))
# Backend.jar is first on the launcher classpath. Recompile the pinned HMCL
# process class with a bounded display buffer while full logs continue to disk.
with tarfile.open(root/'upstream/HMCL-3.16.4-source.tar.gz') as source, tempfile.TemporaryDirectory(prefix='harbor-hmcl-log-') as directory:
    member='HMCL/HMCLCore/src/main/java/org/jackhuang/hmcl/util/platform/ManagedProcess.java'
    text=source.extractfile(member).read().decode()
    old_decl='private final List<String> lines = new ArrayList<>();'
    old_add='lines.add(line);'
    if text.count(old_decl)!=1 or text.count(old_add)!=1:
        raise SystemExit('Pinned HMCL ManagedProcess source changed')
    text=text.replace(old_decl,'private final ArrayDeque<String> lines = new ArrayDeque<>();')
    text=text.replace(old_add,'''if (lines.size() == 256) lines.removeFirst();
            lines.addLast(line.length() <= 4096 ? line : line.substring(0, 4096));''')
    patch=Path(directory)/'ManagedProcess.java'
    patch.write_text(text)
    subprocess.run([str(jdk/'bin/javac'),'--release','17','-encoding','UTF-8','-cp',os.pathsep.join(map(str,[jar]+fx)),'-d',str(classes)]+list(map(str,[*sources,patch])),check=True)
with zipfile.ZipFile(root/'build/Backend.jar','w',zipfile.ZIP_DEFLATED) as out:
 for p in classes.rglob('*.class'):out.write(p,str(p.relative_to(classes)))
print('Backend compiled')
