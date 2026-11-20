"""Local English to Simplified Chinese worker. Standard I/O is UTF-8 JSON lines."""
import argparse
import contextlib
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


MODEL_ID = "opus-en-zh-2020-07-17-ct2-int8-v1"
MODEL_URL = "https://object.pouta.csc.fi/Tatoeba-MT-models/eng-zho/opus-2020-07-17.zip"
MODEL_SHA256 = "ab90e5583fa3ec46d8c5c50f106cbd65221978cd052c7e2059981439325ae24b"
MODEL_DOWNLOAD_SIZE = 288947487
TOKEN = re.compile(
    r"(%(?:(?:\d+)\$)?[-+#0,(<]*\d*(?:\.\d+)?[tT]?[A-Za-z%]"
    r"|\$\{[^{}]+\}|\$\([^()]+\)|\{[^{}\r\n]+\}|(?:&|§)(?:#[0-9a-fA-F]{6}|[0-9A-FK-ORZa-fk-orz])"
    r"|https?://[^\s<>]+|\b[a-z0-9_.-]+:[a-z0-9_./-]+\b|\[\[[^\]\r\n]+\]\]|\r\n|\r|\n)"
)
ENGLISH = re.compile(r"[A-Za-z]")
CHINESE = re.compile(r"[\u3400-\u9fff]")


def emit(**message):
    print(json.dumps(message, ensure_ascii=False), flush=True)


@contextlib.contextmanager
def setup_lock(directory):
    with (directory / "setup.lock").open("a+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise RuntimeError("已有一个 MC Harbor 窗口正在准备本机翻译。") from error
        yield


def install_modules(state):
    target = state / "python-packages-4.8.0-v1"
    if not (target / "ctranslate2" / "__init__.py").is_file():
        emit(event="progress", message="正在准备本机翻译运行库…")
        with tempfile.TemporaryDirectory(prefix="python-", dir=state) as directory:
            stage = Path(directory) / "packages"
            command = [
                sys.executable, "-I", "-m", "pip", "--isolated", "--disable-pip-version-check",
                "install", "--no-cache-dir", "--only-binary=:all:", "--require-hashes",
                "--target", str(stage), "-r", str(Path(__file__).with_name("requirements.txt"))
            ]
            wheels = state / "wheels"
            if wheels.is_dir():
                command.extend(["--no-index", "--find-links", str(wheels)])
            else:
                command.extend(["--index-url", "https://pypi.org/simple"])
            result = subprocess.run(command, stdout=sys.stderr, stderr=sys.stderr, check=False)
            if result.returncode:
                raise RuntimeError("本机翻译运行库下载失败。请检查网络后重试。")
            os.replace(stage, target)
    sys.path.insert(0, str(target))


def model_archive(state):
    archive = state / "opus-2020-07-17.zip"
    if not archive.is_file():
        emit(event="progress", message="正在下载 OPUS-MT 英译中模型，约 289 MB…")
        stage = archive.with_suffix(".partial")
        with urllib.request.urlopen(MODEL_URL, timeout=30) as source, stage.open("wb") as output:
            digest = hashlib.sha256()
            written = 0
            next_report = 24 * 1024 * 1024
            while block := source.read(1024 * 1024):
                written += len(block)
                if written > MODEL_DOWNLOAD_SIZE:
                    raise RuntimeError("模型下载大小不符合预期。")
                digest.update(block)
                output.write(block)
                if written >= next_report:
                    emit(event="progress", message=f"下载 OPUS-MT 模型… {100 * written // MODEL_DOWNLOAD_SIZE}%")
                    next_report += 24 * 1024 * 1024
            if digest.hexdigest() != MODEL_SHA256:
                raise RuntimeError("模型文件校验失败，请重试。")
        os.replace(stage, archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != MODEL_SHA256:
            archive.unlink()
            raise RuntimeError("缓存的模型文件校验失败，请重试。")
    return archive


def prepare_model(state):
    from ctranslate2.converters import OpusMTConverter

    model = state / MODEL_ID
    if (model / "model.bin").is_file():
        return model
    archive = model_archive(state)
    emit(event="progress", message="正在转换本机 INT8 翻译模型…")
    with tempfile.TemporaryDirectory(prefix="opus-", dir=state) as directory:
        scratch = Path(directory)
        with zipfile.ZipFile(archive) as bundle:
            # This archive has already been verified against the fixed release digest.
            for member in bundle.infolist():
                name = Path(member.filename).name
                if name.endswith((".spm", ".npz", ".yml")) or name in ("LICENSE", "README.md"):
                    with bundle.open(member) as origin, (scratch / name).open("wb") as target:
                        shutil.copyfileobj(origin, target)
        destination = scratch / "converted"
        OpusMTConverter(str(scratch)).convert(str(destination), quantization="int8")
        for name in ("source.spm", "target.spm", "LICENSE", "README.md"):
            shutil.copy2(scratch / name, destination / name)
        os.replace(destination, model)
    try:
        archive.unlink()
    except OSError:
        pass
    return model


class TranslationWorker:
    def __init__(self, model, cache):
        import ctranslate2
        import sentencepiece

        self.source = sentencepiece.SentencePieceProcessor(model_file=str(model / "source.spm"))
        self.target = sentencepiece.SentencePieceProcessor(model_file=str(model / "target.spm"))
        self.engine = ctranslate2.Translator(str(model), device="cpu", compute_type="int8", inter_threads=1, intra_threads=1)
        self.cache = cache
        self.cache.execute("CREATE TABLE IF NOT EXISTS translation (id TEXT PRIMARY KEY, text TEXT NOT NULL)")
        self.cache.execute("DELETE FROM translation WHERE rowid <= (SELECT max(rowid)-100000 FROM translation)")

    def translate(self, texts):
        outputs = [None] * len(texts)
        layouts = []
        token_rows = []
        for row, text in enumerate(texts):
            identifier = hashlib.sha256((MODEL_ID + "\0" + text).encode()).hexdigest()
            cached = self.cache.execute("SELECT text FROM translation WHERE id=?", (identifier,)).fetchone()
            if cached:
                outputs[row] = cached[0]
                continue
            if len(text) > 8192:
                continue
            segments = TOKEN.split(text)
            jobs = []
            row_tokens = []
            for index in range(0, len(segments), 2):
                segment = segments[index]
                if not ENGLISH.search(segment):
                    continue
                chunks = self.chunks(segment.strip())
                if not chunks:
                    jobs = []
                    break
                jobs.append((index, len(chunks)))
                row_tokens.extend(chunks)
            if jobs:
                layouts.append((row, identifier, segments, jobs))
                token_rows.extend(row_tokens)

        if not token_rows:
            return outputs
        translations = iter(self.engine.translate_batch(
            token_rows, max_batch_size=24, beam_size=1, max_input_length=256, max_decoding_length=420
        ))
        for row, identifier, segments, jobs in layouts:
            valid = True
            for index, size in jobs:
                pieces = []
                for _ in range(size):
                    tokens = next(translations).hypotheses[0]
                    result = self.target.decode(tokens).strip()
                    if not result or "<unk>" in tokens or len(tokens) >= 420:
                        valid = False
                    pieces.append(result)
                segment = segments[index]
                initial_space = segment[:len(segment) - len(segment.lstrip())]
                final_space = segment[len(segment.rstrip()):]
                segments[index] = initial_space + "".join(pieces) + final_space
            result = "".join(segments)
            if valid and CHINESE.search(result):
                outputs[row] = result
                self.cache.execute("INSERT OR IGNORE INTO translation VALUES (?, ?)", (identifier, result))
        self.cache.commit()
        return outputs

    def chunks(self, text):
        output = []
        for sentence in re.split(r"(?<=[.!?;])\s+", text):
            tokens = self.source.encode(sentence, out_type=str)
            if len(tokens) > 800:
                return []
            output.extend([">>cmn_Hans<<", *tokens[offset:offset + 240]] for offset in range(0, len(tokens), 240))
        return output


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    settings = parser.parse_args()
    state = settings.state_dir.resolve()
    state.mkdir(parents=True, exist_ok=True)
    with setup_lock(state):
        install_modules(state)
        model = prepare_model(state)
    with sqlite3.connect(state / "cache.sqlite3") as cache:
        translator = TranslationWorker(model, cache)
        emit(event="ready")
        for line in sys.stdin:
            request = json.loads(line)
            texts = request["texts"]
            if not isinstance(texts, list) or len(texts) > 32 or not all(isinstance(text, str) for text in texts):
                raise ValueError("补译批次格式无效")
            emit(event="result", translations=translator.translate(texts))


if __name__ == "__main__":
    for variable in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ[variable] = "1"
    try:
        main()
    except Exception as error:
        emit(event="error", message=str(error)[:480] or type(error).__name__)
        sys.exit(1)
