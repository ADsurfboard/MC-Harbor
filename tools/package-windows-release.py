"""Assemble versioned Windows Release assets from one reviewed build and commit."""
from __future__ import annotations

import argparse
import hashlib
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
spec = spec_from_file_location("source_privacy", ROOT / "tools/check-source-privacy.py")
privacy = module_from_spec(spec)
sys.modules[spec.name] = privacy
spec.loader.exec_module(privacy)
MSI_HEADER = bytes.fromhex("d0cf11e0a1b11ae1")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def assemble(portable: Path, installer: Path, source: Path, output: Path,
             version: str, revision: str, root: Path = ROOT) -> list[Path]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
        raise ValueError("Expected a three- or four-part Windows version.")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected a complete source commit SHA.")
    for archive_path, source_archive in ((portable, False), (source, True)):
        _, findings = privacy.scan_zip(archive_path, privacy.personal_markers([]), source=source_archive)
        if findings:
            privacy.print_findings(findings)
            raise ValueError("An input archive failed the source privacy checks.")
    with zipfile.ZipFile(portable) as archive:
        required = {"MC-Harbor-Windows/MC Harbor.exe", "MC-Harbor-Windows/MCHarbor.portable"}
        if not required.issubset(archive.namelist()):
            raise ValueError("The portable ZIP is missing its executable or portable marker.")
    with zipfile.ZipFile(source) as archive:
        if archive.comment != revision.encode("ascii"):
            raise ValueError("The source ZIP must be exported from the current Git commit.")
        metadata = json.loads(archive.read("MC-Harbor-Windows-source/SOURCE.json"))
        if metadata["windows"]["version"] != version:
            raise ValueError("The source ZIP version differs from the release version.")
    with installer.open("rb") as stream:
        if stream.read(8) != MSI_HEADER:
            raise ValueError("The installer is not a Windows Installer compound file.")
    output = output.resolve()
    # Keeping outputs ignored is also required by the corresponding-source exporter.
    output.relative_to((root / "build").resolve())
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use an empty output directory; previous release assets are not overwritten.")
    output.parent.mkdir(parents=True, exist_ok=True)
    stem = f"MC-Harbor-{version}-Windows-x64"
    notes = (root / "docs/WINDOWS_RELEASE.md").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="release-", dir=output.parent) as temporary:
        stage = Path(temporary)
        payloads = []
        for origin, name in ((portable, f"{stem}-portable.zip"),
                             (installer, f"{stem}-Setup.msi"),
                             (source, f"{stem}-source.zip")):
            destination = stage / name
            shutil.copyfile(origin, destination)
            payloads.append(destination)
        bundle = stage / f"{stem}-Setup.zip"
        prefix = f"{stem}-Setup/"
        instruction = (
            f"MC Harbor Windows {version} x64 安装版\n\n"
            "完整解压后，运行同目录的 MSI 安装器；请勿直接在压缩软件中运行。\n"
            "安装到 Program Files，并创建开始菜单入口。\n"
            "安装版数据位置：%LOCALAPPDATA%\\MCHarbor。\n"
            "便携版请另选 portable.zip，其数据保存在程序目录的 MCHarborData。\n"
            "本版未取得公开可信证书签名。安装、升级及卸载仍需目标设备验收。\n"
            "源码、许可证、已验证范围及剩余限制见同一 Release 的源码 ZIP 和发行说明。\n\n"
            f"对应源码提交：{revision}\n"
            f"MSI SHA-256：{sha256(installer)}\n"
        )
        with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(installer, prefix + f"{stem}-Setup.msi")
            archive.writestr(prefix + "INSTALL.txt", instruction.encode("utf-8"))
            archive.writestr(prefix + "WINDOWS_RELEASE.md", notes.encode("utf-8"))
            for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
                archive.write(root / name, prefix + name)
        # A wrong MSI in the wrapper is a different install experience, even with a valid ZIP.
        with zipfile.ZipFile(bundle) as archive:
            digest = hashlib.sha256(archive.read(prefix + f"{stem}-Setup.msi")).hexdigest()
            if digest != sha256(installer):
                raise ValueError("The bundled MSI differs from the standalone installer.")
        _, findings = privacy.scan_zip(bundle, privacy.personal_markers([]), source=False)
        if findings:
            privacy.print_findings(findings)
            raise ValueError("The installer ZIP failed the release privacy checks.")
        payloads.append(bundle)
        checksums = stage / f"SHA256SUMS-{version}-Windows-x64.txt"
        checksums.write_text("".join(f"{sha256(path)}  {path.name}\n"
                                     for path in sorted(payloads)), encoding="ascii", newline="\n")
        release_notes = stage / "RELEASE_NOTES.md"
        release_notes.write_text(notes + f"\n对应源码提交：`{revision}`。\n", encoding="utf-8", newline="\n")
        output.mkdir(parents=True, exist_ok=True)
        files = sorted(stage.iterdir())
        for path in files:
            shutil.move(str(path), output / path.name)
    return [output / path.name for path in files]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", type=Path, default=ROOT / "build/MC-Harbor-Windows-x64-portable.zip")
    parser.add_argument("--installer", type=Path, default=ROOT / "build/MC-Harbor-Windows-x64-Setup.msi")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output-directory", type=Path, default=ROOT / "build/windows-release")
    args = parser.parse_args()
    revision = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
    version = json.loads((ROOT / "SOURCE.json").read_text(encoding="utf-8"))["windows"]["version"]
    source = args.source or ROOT / "build/windows-source" / f"MC-Harbor-Windows-{version}-source.zip"
    files = assemble(args.portable, args.installer, source, args.output_directory, version, revision)
    for path in files:
        print(f"Release asset: {path.name} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
