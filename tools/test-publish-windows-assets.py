"""Offline regression checks for adding Windows files to a shared Release."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = spec_from_file_location("publish_windows_assets", Path(__file__).with_name("publish-windows-assets.py"))
publisher = module_from_spec(spec)
spec.loader.exec_module(publisher)


class SharedReleaseTests(unittest.TestCase):
    def test_existing_mac_files_are_preserved_and_different_windows_files_rejected(self):
        local = {"MC-Harbor-Windows-1.7.1-x64-portable.zip": (42, "sha256:" + "a" * 64)}
        mac = {"name": "MC-Harbor-1.7.1-macOS-arm64.zip", "size": 100, "digest": "sha256:" + "b" * 64}
        self.assertEqual(publisher.missing_assets([mac], local, "1.7.1"), list(local))
        with self.assertRaisesRegex(ValueError, "differs"):
            publisher.missing_assets([mac, {"name": next(iter(local)), "size": 42,
                                            "digest": "sha256:" + "c" * 64}], local, "1.7.1")

    def test_shared_description_keeps_mac_text_and_is_idempotent(self):
        old = "macOS 说明\n\n- 增加windows版**（目前只制作了x64适配）**\n"
        amended = publisher.shared_description(old, "1.7.1", "a" * 40)
        self.assertIn("macOS 说明", amended)
        self.assertNotIn("增加windows版**", amended)
        self.assertIn("### Windows x64（1.7.1）", amended)
        self.assertEqual(publisher.shared_description(amended, "1.7.1", "a" * 40), amended)

    def test_local_manifest_and_source_commit_must_match(self):
        version = "1.7.1"
        revision = "a" * 40
        names = publisher.expected_names(version)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in names[:3]:
                (directory / name).write_bytes(name.encode())
            with zipfile.ZipFile(directory / names[3], "w") as archive:
                archive.comment = revision.encode()
                archive.writestr("SOURCE.json", "{}")
            manifest = "".join(f"{publisher.digest(directory / name)[7:]}  {name}\n" for name in names[:4])
            (directory / names[4]).write_text(manifest, encoding="ascii")
            self.assertEqual(set(publisher.verify_local(directory, version, revision)), set(names))
            with self.assertRaisesRegex(ValueError, "source attachment"):
                publisher.verify_local(directory, version, "b" * 40)
            (directory / names[0]).write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "checksum manifest"):
                publisher.verify_local(directory, version, revision)


if __name__ == "__main__":
    unittest.main()
