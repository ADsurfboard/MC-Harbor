"""Run the production x64 OPUS dependency setup and CPU imports without a model."""
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent.parent
with Path(sys.executable).open("rb") as executable:
    header = executable.read(64)
    if header[:2] != b"MZ":
        raise RuntimeError("Expected the packaged Windows x64 Python executable.")
    executable.seek(struct.unpack_from("<I", header, 0x3C)[0])
    pe = executable.read(6)
    if pe[:4] != b"PE\0\0" or struct.unpack_from("<H", pe, 4)[0] != 0x8664:
        raise RuntimeError("The OPUS compatibility test must execute the actual x64 Python.")

spec = spec_from_file_location("harbor_worker", root / "windows/Translation/worker.py")
worker = module_from_spec(spec)
spec.loader.exec_module(worker)
# Loaded extension DLLs stay mapped until exit on Windows. Keep this disposable
# build cache outside all player data; CI discards the workspace after the job.
state = root / "build/translation-runtime-check"
state.mkdir(parents=True, exist_ok=True)
with worker.setup_lock(state):
    worker.install_modules(state)

import ctranslate2
import numpy
import sentencepiece
import yaml

supported = ctranslate2.get_supported_compute_types("cpu")
if "int8" not in supported:
    raise RuntimeError("The emulated CPU does not expose OPUS INT8 support.")
if not numpy.array_equal(numpy.arange(8).reshape(2, 4) @ numpy.ones(4), [6, 22]):
    raise RuntimeError("Numerical CPU compatibility check failed.")
if yaml.safe_load("mode: cpu\n")["mode"] != "cpu":
    raise RuntimeError("Model configuration parser failed.")
sentencepiece.SentencePieceProcessor()
print(json.dumps({"pythonArchitecture": "x64", "ctranslate2": ctranslate2.__version__,
                  "cpuComputeTypes": sorted(supported), "dependencyImports": "passed",
                  "numericalCpuCheck": "passed", "modelDownloaded": False, "realPlayerData": False}))
