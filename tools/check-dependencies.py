from pathlib import Path
import os,shutil,subprocess
root=Path(__file__).resolve().parent.parent
jdk=Path('/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home')
fixture=root/'evidence/dependency-fixture'
if fixture.exists():shutil.rmtree(fixture)
fixture.mkdir()
classes=root/'build/dependency-check-classes';classes.mkdir(exist_ok=True)
classpath=os.pathsep.join(map(str,[root/'build/Backend.jar',Path('/Applications/稳定版我的世界启动器.jar')]+list(Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar'))))
subprocess.run([str(jdk/'bin/javac'),'--release','17','-encoding','UTF-8','-cp',classpath,'-d',str(classes),str(root/'tools/DependencyChecks.java')],check=True)
subprocess.run([str(jdk/'bin/java'),'-Xmx256m','-Djava.awt.headless=true','-cp',str(classes)+os.pathsep+classpath,'net.morben.shenggan.DependencyChecks',str(fixture)],check=True)
