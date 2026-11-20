"""Export corresponding Windows source from a clean, privacy-checked Git commit."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from importlib.util import module_from_spec, spec_from_file_location
import sys


ROOT = Path(__file__).resolve().parent.parent
spec = spec_from_file_location("source_privacy", ROOT / "tools/check-source-privacy.py")
privacy = module_from_spec(spec)
sys.modules[spec.name] = privacy
spec.loader.exec_module(privacy)


def git(*args: str) -> str:
    return subprocess.run(["git", "-c", f"safe.directory={ROOT.as_posix()}", "-C", str(ROOT), *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path, default=ROOT / "outputs")
    parser.add_argument("--private-marker", action="append", default=[])
    args = parser.parse_args()
    if git("status", "--porcelain"):
        raise SystemExit("Commit the reviewed source changes before exporting their source archive.")
    markers = privacy.personal_markers(args.private_marker)
    _, findings = privacy.scan_directory(ROOT, markers, source=True)
    if findings:
        privacy.print_findings(findings)
        raise SystemExit("Source privacy check failed; no archive was exported.")
    revision = git("rev-parse", "HEAD")
    version = json.loads((ROOT / "SOURCE.json").read_text(encoding="utf-8"))["windows"]["version"]
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"MC-Harbor-Windows-{version}-source.zip"
    with tempfile.TemporaryDirectory(prefix="source-", dir=output) as stage:
        archive = Path(stage) / destination.name
        git("archive", "--format=zip", "--prefix=MC-Harbor-Windows-source/", f"--output={archive}", revision)
        count, findings = privacy.scan_zip(archive, markers, source=True)
        if findings:
            privacy.print_findings(findings)
            raise SystemExit("Exported archive failed privacy checks; no archive was published.")
        archive.replace(destination)
    print(f"Source archive: {destination.name}, {count} files, commit {revision}")


if __name__ == "__main__":
    main()
