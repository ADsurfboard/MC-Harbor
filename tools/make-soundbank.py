"""Build an app soundbank from the officially downloaded JDSherbert free pack.

The original audio and resulting bank are excluded from the public source archive.
The author's terms allow embedding sounds in a finished app binary/soundbank.
"""
from pathlib import Path
import hashlib
import json
import os
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
mapping = {
    "focus": "Cursor - 3",
    "select": "Select - 1",
    "navigate": "Cursor - 1",
    "open": "Popup Open - 1",
    "close": "Popup Close - 1",
    "launch": "Swipe - 2",
    "success": "Select - 2",
    "error": "Error - 1",
    "startup": "Popup Open - 1",
}

mp3_override = os.environ.get("JDS_MP3_DIR")
wav_override = os.environ.get("JDS_WAV_DIR")
mp3_source = Path(mp3_override) if mp3_override else root / "voice-assets/jds-ui-free"
wav_source = Path(wav_override) if wav_override else None
if wav_source is None and not mp3_override and not mp3_source.is_dir():
    print("JDSherbert MP3 pack not present; skipping optional interface soundbank.")
    raise SystemExit(0)
entries = {}
blob = bytearray()

with tempfile.TemporaryDirectory(prefix="harbor-soundbank-") as stage:
    for cue, name in mapping.items():
        if wav_source is not None:
            original = wav_source / f"JDSherbert - Ultimate UI SFX Pack - {name}.wav"
            target = Path(stage) / f"{cue}.wav"
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-y", "-i", str(original),
                    "-af", "silenceremove=start_periods=1:start_duration=0.002:start_threshold=-60dB:stop_periods=1:stop_duration=0.15:stop_threshold=-55dB",
                    "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", str(target),
                ],
                check=True,
            )
            data = target.read_bytes()
        else:
            original = mp3_source / f"JDSherbert - Ultimate UI SFX Pack - {name}.mp3"
            data = original.read_bytes()

        if not data:
            raise ValueError(f"音效文件为空：{original}")
        entries[cue] = {"offset": len(blob), "length": len(data)}
        blob.extend(data)

header = json.dumps(
    {
        "author": "JDSherbert",
        "pack": "Ultimate UI SFX Pack FREE",
        "source": "https://jdsherbert.itch.io/ultimate-ui-sfx-pack",
        "encoding": "audio/mpeg" if wav_source is None else "audio/wav",
        "entries": entries,
    },
    separators=(",", ":"),
).encode("utf-8")
output = root / "build/Interface.soundbank"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(b"MCHSFX01" + struct.pack("<I", len(header)) + header + blob)

(root / "evidence").mkdir(exist_ok=True)
(root / "evidence/soundbank-report.json").write_text(
    json.dumps(
        {
            "source": "https://jdsherbert.itch.io/ultimate-ui-sfx-pack",
            "author": "JDSherbert",
            "files": mapping,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "size": output.stat().st_size,
            "encoding": "audio/mpeg" if wav_source is None else "audio/wav",
            "processing": "Original free-pack MP3 cues embedded byte-for-byte; no raw clips included in the archive.",
        },
        indent=2,
    ),
    encoding="utf-8",
)
print("Built sourced soundbank:", len(entries), "cues,", output.stat().st_size, "bytes")
