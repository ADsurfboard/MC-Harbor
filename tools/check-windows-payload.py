"""Check native PE architectures and explicitly isolated compatibility workers."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct

AMD64, ARM64, ARM64X, I386 = 0x8664, 0xAA64, 0xA64E, 0x14C


def pe_info(path: Path) -> tuple[int, bool]:
    with path.open("rb") as stream:
        dos = stream.read(64)
        if len(dos) != 64 or dos[:2] != b"MZ":
            raise ValueError("missing DOS header")
        offset = struct.unpack_from("<I", dos, 0x3C)[0]
        if offset < 64 or offset > path.stat().st_size - 24:
            raise ValueError("invalid PE offset")
        stream.seek(offset)
        header = stream.read(24)
        if header[:4] != b"PE\0\0":
            raise ValueError("missing PE signature")
        machine, sections = struct.unpack_from("<HH", header, 4)
        optional_size = struct.unpack_from("<H", header, 20)[0]
        optional = stream.read(optional_size)
        if len(optional) != optional_size or optional_size < 96 or not 0 < sections < 128:
            raise ValueError("invalid optional header")
        magic = struct.unpack_from("<H", optional)[0]
        directory = 112 if magic == 0x20B else 96 if magic == 0x10B else 0
        any_cpu = False
        if machine == I386 and directory and len(optional) >= directory + 15 * 8:
            clr_rva, clr_size = struct.unpack_from("<II", optional, directory + 14 * 8)
            for _ in range(sections):
                section = stream.read(40)
                if len(section) != 40:
                    raise ValueError("truncated section table")
                virtual_size, virtual_address, raw_size, raw = struct.unpack_from("<IIII", section, 8)
                if clr_size >= 20 and virtual_address <= clr_rva < virtual_address + min(virtual_size, raw_size):
                    location = raw + clr_rva - virtual_address + 16
                    stream.seek(location)
                    flags = struct.unpack("<I", stream.read(4))[0]
                    any_cpu = bool(flags & 1) and not bool(flags & 2)
                    break
        return machine, any_cpu


def expected_machines(relative: str, architecture: str) -> set[int]:
    name = relative.replace("\\", "/").casefold()
    # These six files are pip's script-generation templates, not launched workers.
    template = "translation/python/lib/site-packages/pip/_vendor/distlib/"
    if name.startswith(template) and name[len(template):] in {"t32.exe", "w32.exe", "t64.exe", "w64.exe", "t64-arm.exe", "w64-arm.exe"}:
        leaf = name[len(template):]
        return {ARM64} if "-arm" in leaf else {I386} if "32" in leaf else {AMD64}
    if name.startswith("translation/python/") or name.startswith("compatibility/javax64/"):
        return {AMD64}
    return {ARM64, ARM64X} if architecture == "arm64" else {AMD64}


def is_arm64x(path: Path) -> bool:
    """Recognize ARM64X's load config and type-6 dynamic relocation table."""
    data = path.read_bytes()
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if struct.unpack_from("<H", data, offset + 4)[0] != ARM64:
        return False  # x64-header ARM64EC alone is not dual-ABI ARM64X.
    sections = struct.unpack_from("<H", data, offset + 6)[0]
    optional_size = struct.unpack_from("<H", data, offset + 20)[0]
    start = offset + 24
    optional = data[start:start + optional_size]
    if len(optional) < 200 or struct.unpack_from("<H", optional)[0] != 0x20B:
        return False
    table = [struct.unpack_from("<IIII", data, start + optional_size + index * 40 + 8) for index in range(sections)]
    def rva_offset(rva, length):
        for virtual_size, virtual_address, raw_size, raw in table:
            if virtual_address <= rva and rva + length <= virtual_address + min(virtual_size, raw_size):
                position = raw + rva - virtual_address
                if position + length <= len(data):
                    return position
        return None
    config_rva, config_size = struct.unpack_from("<II", optional, 112 + 10 * 8)
    config = rva_offset(config_rva, 232)
    if config is None or config_size < 232 or struct.unpack_from("<I", data, config)[0] < 232:
        return False
    metadata = struct.unpack_from("<Q", data, config + 200)[0]
    image_base = struct.unpack_from("<Q", optional, 24)[0]
    if metadata < image_base or rva_offset(metadata - image_base, 4) is None:
        return False
    relocation_offset, relocation_section = struct.unpack_from("<IH", data, config + 224)
    if not 1 <= relocation_section <= sections:
        return False
    _, _, raw_size, raw = table[relocation_section - 1]
    position = raw + relocation_offset
    limit = min(len(data), raw + raw_size)
    if position + 8 > limit:
        return False
    version, size = struct.unpack_from("<II", data, position)
    end = position + 8 + size
    if version != 1 or end > limit:
        return False
    position += 8
    while position + 12 <= end:
        symbol, block_size = struct.unpack_from("<QI", data, position)
        position += 12
        if not block_size or position + block_size > end:
            return False
        if symbol == 6:  # IMAGE_DYNAMIC_RELOCATION_ARM64X
            return True
        position += block_size
    return False


def check(root: Path, architecture: str) -> dict:
    expected = ARM64 if architecture == "arm64" else AMD64
    critical = ["MC Harbor.exe", "coreclr.dll", "Microsoft.UI.Xaml.dll", "Runtime/bin/java.exe", "Runtime/bin/server/jvm.dll"]
    if architecture == "arm64":
        critical.extend(["Runtime/bin/glass.dll", "Compatibility/JavaX64/bin/java.exe", "Compatibility/JavaX64/bin/server/jvm.dll"])
    for name in critical:
        machine, _ = pe_info(root / name)
        wanted = AMD64 if name.startswith("Compatibility/") else expected
        if machine != wanted:
            raise ValueError(f"{name}: unexpected architecture 0x{machine:04x}")
    if pe_info(root / "Translation/Python/python.exe")[0] != AMD64:
        raise ValueError("The pinned CTranslate2 compatibility worker requires x64 Python.")
    required = ["App.xbf", "MainWindow.xbf", "MC Harbor.pri", "Controls/WallpaperLibraryDialog.xbf",
                "Backend/Backend.jar", "Backend/HMCLCore.jar", "Backend/runtime.json", "Assets/App.ico",
                "Assets/Fonts/SourceHanSerifCN-Regular.otf", "Assets/Fonts/SourceHanSerifCN-Bold.otf"]
    for name in required:
        if not (root / name).is_file():
            raise ValueError(f"Missing publish resource: {name}")
    metadata = json.loads((root / "Backend/runtime.json").read_text(encoding="utf-8-sig"))
    if metadata.get("clientArchitecture") != architecture or metadata.get("javaArchitecture") != architecture:
        raise ValueError("Runtime manifest does not match the application architecture.")
    if metadata.get("javaFxMode") != ("modules" if architecture == "arm64" else "classpath"):
        raise ValueError("JavaFX mode does not match its architecture.")
    native = managed = hybrid = 0
    errors = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.casefold() not in {".exe", ".dll", ".pyd"}:
            continue
        relative = path.relative_to(root).as_posix()
        try:
            machine, any_cpu = pe_info(path)
            if any_cpu:
                managed += 1
            elif relative.casefold() == "microsoft.windows.workloads.resources_ec.dll" and is_arm64x(path):
                # The official SDK ships a dual-ABI ARM64X component in x64 too.
                hybrid += 1
            elif machine not in expected_machines(relative, architecture):
                errors.append(f"{relative}: unexpected machine 0x{machine:04x}")
            else:
                native += 1
        except (ValueError, struct.error) as error:
            errors.append(f"{relative}: {error}")
    if errors:
        raise ValueError("\n".join(errors))
    return {"architecture": architecture, "nativeFiles": native, "anyCpuAssemblies": managed, "arm64xFiles": hybrid,
            "gameArchitecture": "x64", "translationPythonArchitecture": "x64"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=("x64", "arm64"))
    args = parser.parse_args()
    print(json.dumps(check(args.directory.resolve(), args.architecture)))
