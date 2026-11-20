"""Regression checks for rejecting foreign native binaries in Windows packages."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import struct
import tempfile
import unittest

spec = spec_from_file_location("payload_checks", Path(__file__).with_name("check-windows-payload.py"))
payload = module_from_spec(spec)
spec.loader.exec_module(payload)


def image(machine: int, clr_flags: int | None = None) -> bytes:
    result = bytearray(1536)
    result[:2] = b"MZ"
    struct.pack_into("<I", result, 0x3C, 64)
    result[64:68] = b"PE\0\0"
    struct.pack_into("<HH", result, 68, machine, 1)
    struct.pack_into("<H", result, 84, 224)
    struct.pack_into("<H", result, 88, 0x10B)
    if clr_flags is not None:
        struct.pack_into("<II", result, 88 + 96 + 14 * 8, 0x2000, 72)
        struct.pack_into("<IIII", result, 88 + 224 + 8, 512, 0x2000, 512, 512)
        struct.pack_into("<I", result, 512 + 16, clr_flags)
    return bytes(result)


class ArchitectureChecks(unittest.TestCase):
    def inspect(self, data):
        with tempfile.TemporaryDirectory(prefix="harbor-pe-check-") as folder:
            path = Path(folder) / "fixture.dll"
            path.write_bytes(data)
            return payload.pe_info(path)

    def test_native_architectures_are_not_anycpu(self):
        for machine in (payload.AMD64, payload.ARM64, payload.I386):
            self.assertEqual(self.inspect(image(machine)), (machine, False))

    def test_managed_anycpu_is_distinguished_from_x86_native(self):
        self.assertEqual(self.inspect(image(payload.I386, 1)), (payload.I386, True))

    def test_managed_32bit_required_is_not_anycpu(self):
        self.assertEqual(self.inspect(image(payload.I386, 3)), (payload.I386, False))

    def test_corrupt_headers_fail(self):
        invalid = bytearray(image(payload.ARM64))
        struct.pack_into("<I", invalid, 0x3C, 0xFFFFFFFF)
        for data in (b"", b"MZ", bytes(1536), bytes(invalid)):
            with self.assertRaises(ValueError):
                self.inspect(data)

    def test_x64_is_rejected_from_arm_main_program(self):
        for name in ("MC Harbor.exe", "Runtime/bin/server/jvm.dll", "Microsoft.UI.Xaml.dll"):
            self.assertNotIn(payload.AMD64, payload.expected_machines(name, "arm64"))

    def test_isolated_compatibility_workers_are_x64(self):
        for name in ("Compatibility/JavaX64/bin/server/jvm.dll", "Translation/Python/python.exe"):
            self.assertEqual(payload.expected_machines(name, "arm64"), {payload.AMD64})

    def test_compatibility_exceptions_do_not_match_nearby_paths(self):
        for name in ("Compatibility/JavaX64Extra/foreign.dll", "Translation/PythonExtra/foreign.dll"):
            self.assertNotIn(payload.AMD64, payload.expected_machines(name, "arm64"))

    def test_only_known_pip_templates_allow_other_architectures(self):
        base = "Translation/Python/Lib/site-packages/pip/_vendor/distlib/"
        self.assertEqual(payload.expected_machines(base + "t32.exe", "arm64"), {payload.I386})
        self.assertEqual(payload.expected_machines(base + "w64-arm.exe", "arm64"), {payload.ARM64})
        self.assertEqual(payload.expected_machines(base + "foreign.exe", "arm64"), {payload.AMD64})


if __name__ == "__main__":
    unittest.main()
