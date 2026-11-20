"""Check release candidates without printing matched personal data or secrets."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from fnmatch import fnmatchcase
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PRIVATE_DIRECTORIES = {
    ".git", ".codex", ".claude", ".cursor", ".copilot", ".vs", ".idea", ".vscode",
    ".minecraft", ".wrangler", "mcharbordata", "shenggandata", "voice-assets",
    "sessions", "rollouts", "chat-history", "chat_history", "node_modules", "__pycache__",
}
PRIVATE_NAMES = {
    "agents.md", "agents.local.md", "claude.md", "claude.local.md", ".cursorrules",
    "accounts.json", "hmcl.json", "auth.json", "credentials.json", "hosts.yml",
}
PRIVATE_SUFFIXES = {".jsonl", ".log", ".dpapi", ".pfx", ".p12", ".key", ".pdb", ".suo", ".user", ".pyc", ".pyo"}
SECRET_PATTERNS = {
    "private-key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "github-credential": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "service-credential": re.compile(rb"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}|AKIA[A-Z0-9]{16})\b"),
}


@dataclass(frozen=True)
class Finding:
    path: str
    category: str
    line: int | None = None


def path_findings(name: str, *, source: bool) -> list[Finding]:
    path = PurePosixPath(name.replace("\\", "/"))
    parts = [part.casefold() for part in path.parts]
    leaf = parts[-1] if parts else ""
    if path.is_absolute() or ".." in parts or (parts and ":" in parts[0]):
        return [Finding(name, "unsafe-archive-path")]
    if any(part in PRIVATE_DIRECTORIES for part in parts):
        return [Finding(name, "private-directory")]
    if source and any(part in {"build", "outputs", "evidence", "_tools", "bin", "obj"} for part in parts):
        return [Finding(name, "generated-or-local-directory")]
    if leaf in PRIVATE_NAMES or PurePosixPath(leaf).suffix in PRIVATE_SUFFIXES:
        return [Finding(name, "private-file")]
    if (leaf == ".env" or fnmatchcase(leaf, ".env.*")) and leaf != ".env.example":
        return [Finding(name, "environment-secrets")]
    return []


def personal_markers(extra: list[str]) -> list[str]:
    # Restrict automatic markers to actual home directories, not public author names.
    markers = list(extra)
    for variable in ("USERPROFILE", "HOME"):
        home = os.environ.get(variable)
        if home and len(home) > 5 and home not in {"/root", "/home", "/Users"}:
            markers.append(home)
    return sorted({marker for item in markers for marker in (item, item.replace("\\", "/"), item.replace("/", "\\")) if marker})


def data_findings(name: str, data: bytes, markers: list[str]) -> list[Finding]:
    findings = []
    binary = b"\0" in data[:8192]
    for category, pattern in SECRET_PATTERNS.items():
        match = pattern.search(data)
        if match:
            findings.append(Finding(name, category, None if binary else data.count(b"\n", 0, match.start()) + 1))
    lower = data.lower()
    for marker in markers:
        if any(marker.encode(encoding).lower() in lower for encoding in ("utf-8", "utf-16-le")):
            findings.append(Finding(name, "personal-path-or-marker"))
            break
    return findings


def source_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-c", f"safe.directory={root.as_posix()}", "-C", str(root),
         "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True,
    )
    return sorted({name.decode("utf-8") for name in result.stdout.split(b"\0") if name})


def scan_directory(root: Path, markers: list[str], *, source: bool) -> tuple[int, list[Finding]]:
    names = source_files(root) if source else sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())
    findings = []
    for name in names:
        findings.extend(path_findings(name, source=source))
        path = root / name
        if path.is_symlink():
            findings.append(Finding(name, "source-symlink"))
        elif not path.is_file():
            findings.append(Finding(name, "missing-source-file"))
        else:
            findings.extend(data_findings(name, path.read_bytes(), markers))
    return len(names), findings


def scan_zip(path: Path, markers: list[str], *, source: bool) -> tuple[int, list[Finding]]:
    findings = []
    names = set()
    count = 0
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            count += 1
            normalized = item.filename.replace("\\", "/").casefold()
            if normalized in names:
                findings.append(Finding(item.filename, "duplicate-archive-path"))
            names.add(normalized)
            findings.extend(path_findings(item.filename, source=source))
            if item.external_attr >> 16 & 0o170000 == 0o120000:
                findings.append(Finding(item.filename, "archive-symlink"))
            findings.extend(data_findings(item.filename, archive.read(item), markers))
    return count, findings


def print_findings(findings: list[Finding], limit: int = 30) -> None:
    for finding in findings[:limit]:
        location = finding.path + (f":{finding.line}" if finding.line else "")
        print(f"{location}: {finding.category}")
    if len(findings) > limit:
        print(f"{len(findings) - limit} additional findings omitted from display.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--directory", type=Path, help="A clean program payload, without source Git metadata.")
    target.add_argument("--zip", type=Path, help="Inspect an archive without extracting it.")
    parser.add_argument("--source-archive", action="store_true", help="Apply source-only exclusions to ZIP entries.")
    parser.add_argument("--private-marker", action="append", default=[], help="Additional private path/text to detect; matches are never printed.")
    args = parser.parse_args()
    markers = personal_markers(args.private_marker)
    if args.zip:
        count, findings = scan_zip(args.zip.resolve(), markers, source=args.source_archive)
    else:
        count, findings = scan_directory(args.directory.resolve() if args.directory else ROOT, markers, source=args.directory is None)
    print_findings(findings)
    print(f"Privacy check: {count} files, {len(findings)} findings.")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
