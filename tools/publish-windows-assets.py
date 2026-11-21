"""Attach a reviewed Windows build to the matching shared Latest Release."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile


REPOSITORY = "ADsurfboard/MC-Harbor"
ROOT = Path(__file__).resolve().parent.parent


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


def expected_names(version: str) -> tuple[str, ...]:
    stem = f"MC-Harbor-{version}-Windows-x64"
    return (
        f"{stem}-portable.zip",
        f"{stem}-Setup.zip",
        f"{stem}-Setup.msi",
        f"{stem}-source.zip",
        f"SHA256SUMS-{version}-Windows-x64.txt",
    )


def verify_local(directory: Path, version: str, revision: str) -> dict[str, tuple[int, str]]:
    names = expected_names(version)
    files = {name: directory / name for name in names}
    if any(not path.is_file() for path in files.values()):
        raise ValueError("A required Windows Release attachment is missing.")
    checksums = {}
    for line in files[names[4]].read_text(encoding="ascii").splitlines():
        checksum, name = line.split("  ", 1)
        if name in checksums or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError("The Windows checksum manifest is invalid.")
        checksums[name] = "sha256:" + checksum
    if set(checksums) != set(names[:4]):
        raise ValueError("The Windows checksum manifest names the wrong packages.")
    local = {name: (path.stat().st_size, digest(path)) for name, path in files.items()}
    if any(size <= 0 for size, _ in local.values()):
        raise ValueError("A Windows attachment is empty.")
    if any(local[name][1] != checksum for name, checksum in checksums.items()):
        raise ValueError("A Windows attachment differs from its checksum manifest.")
    with zipfile.ZipFile(files[names[3]]) as archive:
        if archive.comment.decode("ascii") != revision:
            raise ValueError("The Windows source attachment does not match the release tag.")
    return local


def missing_assets(assets: list[dict], local: dict[str, tuple[int, str]], version: str) -> list[str]:
    by_name = {asset["name"]: asset for asset in assets}
    stem = f"MC-Harbor-{version}-Windows-x64"
    legacy = f"MC-Harbor-Windows-{version}"
    extras = {name for name in by_name if (name.startswith(stem) or name.startswith(legacy)
              or name in {f"SHA256SUMS-windows-{version}.txt", f"SHA256SUMS-{version}-Windows-x64.txt"})
              and name not in local}
    if extras:
        raise ValueError("The shared Release has unexpected Windows attachments.")
    for name, (size, sha) in local.items():
        if name in by_name and (by_name[name]["size"] != size or by_name[name].get("digest") != sha):
            raise ValueError("An existing Windows attachment differs: " + name)
    return [name for name in local if name not in by_name]


def windows_section(version: str, revision: str) -> str:
    stem = f"MC-Harbor-{version}-Windows-x64"
    return f"""### Windows x64（{version}）

- **安装版 ZIP**：`{stem}-Setup.zip`，包含中文 MSI、安装说明及许可文件；也可单独下载 `{stem}-Setup.msi`。
- **便携版 ZIP**：`{stem}-portable.zip`，完整解压后运行 `MC Harbor.exe`。
- `{stem}-source.zip` 是对应 Windows 提交的源码；`SHA256SUMS-{version}-Windows-x64.txt` 用于核对四份 Windows 下载文件。

安装版数据保存在 `%LOCALAPPDATA%\\MCHarbor`，便携版数据保存在程序目录的 `MCHarborData`。安装版 ZIP 中的 MSI 与单独下载的 MSI 一致。此处为 x64 附件说明；程序和 MSI 尚未使用公开可信证书签名。发行附件不包含账号、存档或私人配置；实际安装、升级、卸载、在线账号及不同设备环境仍需实机验证。Windows 源码提交：`{revision}`。"""


def shared_description(body: str, version: str, revision: str) -> str:
    marker = f"### Windows x64（{version}）"
    if marker in body:
        return body
    old_placeholder = "- 增加windows版**（目前只制作了x64适配）**"
    body = body.replace(old_placeholder, "")
    if "### 验证与边界" in body:
        return body.replace("### 验证与边界", windows_section(version, revision) + "\n\n### 验证与边界", 1)
    return body.rstrip() + "\n\n" + windows_section(version, revision) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    version = os.environ["RELEASE_VERSION"]
    tag = os.environ["RELEASE_TAG"]
    revision = os.environ["GITHUB_SHA"]
    repository = os.environ["GH_REPO"]
    token = os.environ["GH_TOKEN"]
    if repository != REPOSITORY or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise SystemExit("Unexpected repository or Windows version.")
    if tag != f"windows-v{version}" or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit("Windows tag or commit differs from the version.")
    if json.loads((ROOT / "SOURCE.json").read_text(encoding="utf-8"))["windows"]["version"] != version:
        raise SystemExit("The checked-out Windows source version differs.")
    local = verify_local(args.directory, version, revision)

    def api(path: str, method: str = "GET", body: dict | None = None) -> dict:
        request = Request(
            "https://api.github.com" + path,
            method=method,
            data=None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": "Bearer " + token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
                "User-Agent": "MC-Harbor-Windows-shared-release",
            },
        )
        try:
            with urlopen(request, timeout=60) as response:
                return json.load(response)
        except HTTPError as error:
            try:
                message = json.loads(error.read().decode("utf-8")).get("message", "Request failed")
            except (UnicodeDecodeError, ValueError):
                message = "Request failed"
            raise SystemExit(f"GitHub HTTP {error.code}: {message}") from None
        except URLError:
            raise SystemExit("GitHub could not be reached.") from None

    base = "/repos/" + REPOSITORY
    shared_tag = "v" + version
    release = api(base + "/releases/tags/" + shared_tag)
    latest = api(base + "/releases/latest")
    if release["id"] != latest["id"] or release["draft"] or release["prerelease"]:
        raise SystemExit("The matching public macOS Release must be Latest before adding Windows.")
    original_assets = {asset["name"]: (asset["size"], asset.get("digest"))
                       for asset in release["assets"] if asset["name"] not in local}
    to_upload = missing_assets(release["assets"], local, version)
    for name in to_upload:
        size, expected_sha = local[name]
        connection = http.client.HTTPSConnection("uploads.github.com", timeout=180)
        connection.putrequest("POST", f"/repos/{REPOSITORY}/releases/{release['id']}/assets?name={quote(name)}")
        connection.putheader("Authorization", "Bearer " + token)
        connection.putheader("Accept", "application/vnd.github+json")
        connection.putheader("X-GitHub-Api-Version", "2022-11-28")
        connection.putheader("User-Agent", "MC-Harbor-Windows-shared-release")
        connection.putheader("Content-Type", "application/octet-stream")
        connection.putheader("Content-Length", str(size))
        connection.endheaders()
        with (args.directory / name).open("rb") as stream:
            for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                connection.send(chunk)
        response = connection.getresponse()
        reply = response.read()
        connection.close()
        if response.status != 201:
            raise SystemExit(f"GitHub rejected {name}: HTTP {response.status}")
        uploaded = json.loads(reply)
        if uploaded["size"] != size or uploaded.get("digest") != expected_sha:
            raise SystemExit("GitHub's uploaded attachment differs: " + name)
        print("Uploaded and verified: " + name, flush=True)

    release = api(base + "/releases/" + str(release["id"]))
    missing_assets(release["assets"], local, version)
    by_name = {asset["name"]: asset for asset in release["assets"]}
    if any(name not in by_name for name in local):
        raise SystemExit("The shared Release is missing Windows attachments.")
    if any(name not in by_name or (by_name[name]["size"], by_name[name].get("digest")) != values
           for name, values in original_assets.items()):
        raise SystemExit("An existing macOS Release attachment changed.")
    body = shared_description(release["body"] or "", version, revision)
    title = release["name"] if "Windows" in release["name"] else release["name"] + "（macOS / Windows x64）"
    if body != release["body"] or title != release["name"]:
        if api(base + "/releases/latest")["id"] != release["id"]:
            raise SystemExit("The matching shared Release is no longer Latest.")
        release = api(base + "/releases/" + str(release["id"]), "PATCH", {"body": body, "name": title})
    if release["body"] != body or release["draft"] or release["prerelease"]:
        raise SystemExit("The shared Release was not updated as expected.")
    if api(base + "/releases/latest")["id"] != release["id"]:
        raise SystemExit("The shared Release is no longer Latest.")
    print("Verified shared Latest Release: " + release["html_url"])


if __name__ == "__main__":
    main()
