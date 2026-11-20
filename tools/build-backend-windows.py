from __future__ import annotations

import os
import re
import shutil
import subprocess
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def find_jdk() -> Path:
    configured = os.environ.get("JAVA_HOME")
    if configured:
        home = Path(configured)
        if (home / "bin" / "javac.exe").is_file():
            return home

    javac = shutil.which("javac.exe") or shutil.which("javac")
    if javac:
        candidate = Path(javac).resolve().parent.parent
        if (candidate / "bin" / "javac.exe").is_file():
            return candidate

    roots: list[Path] = []
    for variable in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
        value = os.environ.get(variable)
        if value:
            base = Path(value)
            roots.extend(base / vendor for vendor in ("Java", "Eclipse Adoptium", "Microsoft", "Zulu"))

    matches: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for javac_path in root.glob("**/bin/javac.exe"):
            matches.append(javac_path.parent.parent)
    for candidate in sorted(set(matches), reverse=True):
        version = subprocess.run(
            [str(candidate / "bin" / "javac.exe"), "-version"],
            capture_output=True,
            text=True,
            check=False,
        )
        found = re.search(r"javac\s+(\d+)", version.stdout + version.stderr)
        if found and found.group(1) == "21":
            return candidate
    raise SystemExit("需要 JDK 21。请设置 JAVA_HOME 指向 Windows x64 JDK 21。")


def find_hmcl_jar() -> Path:
    configured = os.environ.get("HMCL_CORE_JAR")
    jar = Path(configured) if configured else ROOT / "vendor" / "HMCLCore.jar"
    if not jar.is_file():
        raise SystemExit(f"找不到固定 HMCL 内核：{jar}")
    return jar.resolve()


def find_javafx() -> list[Path]:
    appdata = Path(os.environ.get("APPDATA", Path.home()))
    choices = [
        Path(os.environ["HMCL_FX_DIR"]) if os.environ.get("HMCL_FX_DIR") else None,
        ROOT / "vendor" / "javafx-windows-x64",
        appdata / ".hmcl" / "dependencies" / "windows-x64" / "openjfx",
    ]
    for directory in (item for item in choices if item is not None):
        jars = sorted(directory.glob("*21.0.8*.jar")) if directory.is_dir() else []
        required = ("base", "graphics", "controls")
        selected = [next((jar for jar in jars if f"javafx-{module}" in jar.name.lower()), None) for module in required]
        if all(selected):
            return [item.resolve() for item in selected if item is not None]
    raise SystemExit(
        "找不到 Windows x64 OpenJFX 21.0.8 的 base、graphics、controls JAR。"
        "请将 HMCL_FX_DIR 指向 HMCL 已下载的 windows-x64/openjfx 目录。"
    )


def main() -> None:
    jdk = find_jdk()
    compiler = jdk / "bin" / "javac.exe"
    version = subprocess.run([str(compiler), "-version"], capture_output=True, text=True, check=True)
    if not re.search(r"javac\s+21(?:\D|$)", version.stdout + version.stderr):
        raise SystemExit(f"后端固定使用 JDK 21，当前版本为：{(version.stdout + version.stderr).strip()}")

    core = find_hmcl_jar()
    javafx = find_javafx()
    build = ROOT / "build"
    classes = build / "backend-classes"
    classes.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / "backend").rglob("*.java"))
    if not sources:
        raise SystemExit("backend/ 下没有 Java 源码。")

    subprocess.run(
        [
            str(compiler),
            "--release",
            "17",
            "-encoding",
            "UTF-8",
            "-cp",
            os.pathsep.join(map(str, [core, *javafx])),
            "-d",
            str(classes),
            *map(str, sources),
        ],
        check=True,
    )

    output = build / "Backend.jar"
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for class_file in sorted(classes.rglob("*.class")):
            archive.write(class_file, class_file.relative_to(classes).as_posix())
    print(f"Windows backend compiled: {output}")


if __name__ == "__main__":
    main()
