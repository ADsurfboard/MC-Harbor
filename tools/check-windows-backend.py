"""Exercise packaged native/compatibility Java using disposable data and no accounts."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--directory", required=True, type=Path)
parser.add_argument("--architecture", required=True, choices=("x64", "arm64"))
args = parser.parse_args()
root = args.directory.resolve()


def invoke(java: Path, data: Path, request: dict, modules: bool):
    paths = [root / "Backend/Backend.jar", root / "Backend/HMCLCore.jar"]
    flags = ["--add-modules", "javafx.controls"] if modules else []
    if not modules:
        paths.append(root / "Backend/javafx/*")
    command = [str(java), *flags, "-Dfile.encoding=UTF-8", "-Djava.awt.headless=true", "-Dshenggan.headless=true",
               "-Dhmcl.dir=" + str(data), "-cp", ";".join(map(str, paths)), "net.morben.shenggan.NativeBridge"]
    result = subprocess.run(command, input=json.dumps(request), text=True, encoding="utf-8", capture_output=True, timeout=60)
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    answers = [row["data"] for row in events if row.get("event") == "result"]
    if result.returncode or not answers:
        kinds = [row.get("event") for row in events]
        raise RuntimeError(f"Packaged backend failed: exit={result.returncode}, events={kinds}")
    return answers[-1]


with tempfile.TemporaryDirectory(prefix="harbor-arm-check-") as temporary:
    base = Path(temporary)
    java = root / "Runtime/bin/java.exe"
    modules = args.architecture == "arm64"
    native = invoke(java, base / "native", {"command": "platformInfo"}, modules)
    expected = {"arm64": {"aarch64", "arm64"}, "x64": {"amd64", "x86_64"}}[args.architecture]
    if native["javaArchitecture"] not in expected or native["javaFxModules"] != modules:
        raise RuntimeError("Packaged backend reported a mismatched native architecture or JavaFX mode.")
    game = native
    if modules:
        game = invoke(root / "Compatibility/JavaX64/bin/java.exe", base / "game", {"command": "platformInfo"}, False)
        if game["javaArchitecture"] not in {"amd64", "x86_64"} or game["javaFxModules"]:
            raise RuntimeError("Game compatibility backend is not x64/classpath.")
    if game["gamePlatform"] != game["currentPlatform"]:
        raise RuntimeError("Game downloads must use the compatibility process architecture.")
    game_java = root / ("Compatibility/JavaX64/bin/java.exe" if modules else "Runtime/bin/java.exe")
    inspected = invoke(game_java, base / "inspect", {"command": "inspectJava", "gameJava": str(game_java)}, False)
    if not inspected.get("compatibleArchitecture"):
        raise RuntimeError("Packaged game Java failed the actual architecture compatibility check.")
    # A second command actually loads shared repository/property classes through JavaFX.
    instance = base / "empty-game"
    run = instance / "versions/fixture"
    run.mkdir(parents=True)
    (run / "fixture.json").write_text(json.dumps({"id": "fixture", "type": "release", "libraries": [],
        "mainClass": "net.minecraft.client.main.Main", "minecraftArguments": ""}), encoding="utf-8")
    packs = run / "resourcepacks"
    packs.mkdir()
    with zipfile.ZipFile(packs / "fixture.zip", "w") as archive:
        archive.writestr("pack.mcmeta", json.dumps({"pack": {"pack_format": 15, "description": "Disposable fixture"}}))
    resources = invoke(java, base / "resources", {"command": "resources", "root": str(instance),
                       "runDirectory": str(run), "id": "fixture", "resolve": False}, modules)
    if "resources" not in resources or len(resources["resources"]) != 1:
        raise RuntimeError("Resource scan did not return its expected schema.")
    print(json.dumps({"nativeJava": native["javaArchitecture"], "javaFxModules": modules,
                      "gameJava": game["javaArchitecture"], "gamePlatform": game["gamePlatform"],
                      "systemPlatform": game["systemPlatform"], "javaInspection": "passed",
                      "resourceScan": "passed", "realPlayerData": False}))
