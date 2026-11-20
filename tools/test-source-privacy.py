"""Regression checks for the source/release privacy gate, using synthetic inputs."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

spec = spec_from_file_location("source_privacy", Path(__file__).with_name("check-source-privacy.py"))
privacy = module_from_spec(spec)
sys.modules[spec.name] = privacy
spec.loader.exec_module(privacy)


class PrivacyChecks(unittest.TestCase):
    def test_agent_records_blocked(self):
        for path in (".codex/config.toml", "data/sessions/conversation.json", "AGENTS.md", "rollout.jsonl"):
            with self.subTest(path=path):
                self.assertTrue(privacy.path_findings(path, source=True))

    def test_player_data_and_encrypted_secrets_blocked(self):
        for path in ("MCHarborData/accounts.json", "secrets/example.dpapi", ".env.local", "signing.pfx"):
            with self.subTest(path=path):
                self.assertTrue(privacy.path_findings(path, source=False))

    def test_runtime_bin_allowed_only_in_distribution(self):
        self.assertFalse(privacy.path_findings("Runtime/bin/java.exe", source=False))
        self.assertTrue(privacy.path_findings("windows/obj/generated.cs", source=True))
        self.assertTrue(privacy.path_findings("Translation/Python/Lib/__pycache__/module.pyc", source=False))

    def test_public_sources_and_attribution_allowed(self):
        self.assertFalse(privacy.path_findings("Sources/Chat.swift", source=True))
        self.assertFalse(privacy.data_findings("LICENSE", b"Copyright contributor <maintainer@example.org>", []))
        self.assertFalse(privacy.path_findings(".env.example", source=True))

    def test_synthetic_credential_detected_without_returning_value(self):
        sample = b"ghp" + b"_" + b"A" * 36
        findings = privacy.data_findings("sample.txt", b"first line\n" + sample, [])
        self.assertEqual(findings, [privacy.Finding("sample.txt", "github-credential", 2)])
        self.assertNotIn(sample.decode(), repr(findings))

    def test_personal_path_detected_in_utf8_and_utf16(self):
        marker = "C:/Users/fixture-person"
        for encoding in ("utf-8", "utf-16-le"):
            with self.subTest(encoding=encoding):
                self.assertEqual(privacy.data_findings("binary.dll", (marker + "/source.cs").encode(encoding), [marker]),
                                 [privacy.Finding("binary.dll", "personal-path-or-marker")])

    def test_unsafe_archive_paths_blocked(self):
        for path in ("../private.json", "/absolute/path", "C:/private.txt"):
            with self.subTest(path=path):
                self.assertTrue(privacy.path_findings(path, source=False))

    def test_archive_entries_inspected_without_extraction(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "example.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("app/.codex/config.toml", "private settings")
                output.writestr("app/secrets.txt", b"ghp" + b"_" + b"A" * 36)
            count, findings = privacy.scan_zip(archive, [], source=False)
            self.assertEqual(count, 2)
            self.assertEqual({item.category for item in findings}, {"private-directory", "github-credential"})
            self.assertEqual(list(Path(folder).iterdir()), [archive])


if __name__ == "__main__":
    unittest.main()
