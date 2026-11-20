"""Check release contents, provenance, integrity and failed-output behavior offline."""
from importlib.util import module_from_spec, spec_from_file_location
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = spec_from_file_location("windows_release", Path(__file__).with_name("package-windows-release.py"))
release = module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/WINDOWS_RELEASE.md").write_text("Windows 预览版；尚未签名。", encoding="utf-8")
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (self.root / name).write_text("public license", encoding="utf-8")
        self.portable = self.root / "portable.zip"
        with zipfile.ZipFile(self.portable, "w") as archive:
            archive.writestr("MC-Harbor-Windows/MC Harbor.exe", b"fixture executable")
            archive.writestr("MC-Harbor-Windows/MCHarbor.portable", b"")
        self.installer = self.root / "Setup.msi"
        self.installer.write_bytes(release.MSI_HEADER + b"fixture MSI payload")
        self.source = self.root / "source.zip"
        self.revision = "a" * 40
        self.write_source()
        self.output = self.root / "build/windows-release"

    def write_source(self, revision=None, version="1.7.1"):
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.comment = (revision or self.revision).encode("ascii")
            archive.writestr("MC-Harbor-Windows-source/SOURCE.json",
                             json.dumps({"windows": {"version": version}}))

    def assemble(self):
        return release.assemble(self.portable, self.installer, self.source, self.output,
                                "1.7.1", self.revision, self.root)

    def test_complete_release_and_identical_installer(self):
        paths = self.assemble()
        self.assertEqual(len(paths), 6)
        checksums = self.output / "SHA256SUMS-windows-1.7.1.txt"
        self.assertEqual(len(checksums.read_text().splitlines()), 4)
        for line in checksums.read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
        with zipfile.ZipFile(self.output / "MC-Harbor-Windows-1.7.1-x64-Setup.zip") as archive:
            prefix = "MC-Harbor-Windows-1.7.1-x64-Setup/"
            self.assertEqual(archive.read(prefix + "MC-Harbor-Windows-1.7.1-x64-Setup.msi"),
                             self.installer.read_bytes())
            self.assertIn(self.revision, archive.read(prefix + "INSTALL.txt").decode("utf-8"))
            self.assertIn(prefix + "LICENSE", archive.namelist())
            self.assertIn(prefix + "THIRD_PARTY_NOTICES.md", archive.namelist())
        self.assertEqual((self.output / "MC-Harbor-Windows-1.7.1-x64-portable.zip").read_bytes(),
                         self.portable.read_bytes())
        self.assertIn(self.revision, (self.output / "RELEASE_NOTES.md").read_text(encoding="utf-8"))

    def test_wrong_source_commit_is_rejected(self):
        self.write_source(revision="b" * 40)
        with self.assertRaisesRegex(ValueError, "current Git commit"):
            self.assemble()
        self.assertFalse(self.output.exists())

    def test_wrong_source_version_is_rejected(self):
        self.write_source(version="1.7.0")
        with self.assertRaisesRegex(ValueError, "version differs"):
            self.assemble()

    def test_private_file_is_rejected(self):
        with zipfile.ZipFile(self.portable, "a") as archive:
            archive.writestr("MC-Harbor-Windows/accounts.json", "{}")
        with self.assertRaisesRegex(ValueError, "privacy"):
            self.assemble()
        self.assertFalse(self.output.exists())

    def test_missing_portable_marker_is_rejected(self):
        with zipfile.ZipFile(self.portable, "w") as archive:
            archive.writestr("MC-Harbor-Windows/MC Harbor.exe", b"fixture")
        with self.assertRaisesRegex(ValueError, "portable marker"):
            self.assemble()

    def test_previous_assets_are_preserved(self):
        self.output.mkdir(parents=True)
        sentinel = self.output / "previous.zip"
        sentinel.write_bytes(b"previous release")
        with self.assertRaisesRegex(ValueError, "empty output"):
            self.assemble()
        self.assertEqual(sentinel.read_bytes(), b"previous release")

    def test_output_must_stay_in_build(self):
        self.output = self.root / "source-directory"
        with self.assertRaises(ValueError):
            self.assemble()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
