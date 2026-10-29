#!/usr/bin/env python3
"""Download pinned build tools or a named test fixture; verify SHA-256."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import time
import urllib.request
import zipfile

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def download(item, directory):
    directory.mkdir(parents=True, exist_ok=True)
    filename = item["filename"]
    if Path(filename).name != filename:
        raise ValueError("Artifact filename must be a basename")
    final = directory / filename
    if final.exists():
        if digest(final) != item["sha256"]:
            raise ValueError("Existing artifact has wrong digest: " + filename)
        print("Verified cached " + filename, flush=True)
        return final
    with tempfile.NamedTemporaryFile(prefix=filename + ".", suffix=".part", dir=directory, delete=False) as stage:
        temporary = Path(stage.name)
    expected_total = None
    try:
        for attempt in range(6):
            offset = temporary.stat().st_size
            if expected_total is not None and offset == expected_total:
                if digest(temporary) != item["sha256"]:
                    raise ValueError("SHA-256 mismatch for complete " + filename)
                temporary.replace(final)
                print("Downloaded and verified " + filename, flush=True)
                return final
            headers = {"User-Agent": "faw-rea-toolbox/0.1.0"}
            if offset:
                headers["Range"] = "bytes=" + str(offset) + "-"
            request = urllib.request.Request(item["url"], headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=120) as source:
                    status = getattr(source, "status", None)
                    append = status == 206 and offset > 0
                    if status == 206:
                        import re
                        match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", source.headers.get("Content-Range", ""))
                        if not match or int(match[1]) != offset:
                            raise ValueError("Invalid resume response for " + filename)
                        expected_total = int(match[3])
                    else:
                        # A server may ignore Range. Restart rather than append duplicate bytes.
                        offset = 0
                        length = source.headers.get("Content-Length")
                        expected_total = int(length) if length is not None else None
                    with temporary.open("ab" if append else "wb") as out:
                        shutil.copyfileobj(source, out, length=1024 * 1024)
                received = temporary.stat().st_size
                if expected_total is not None and received < expected_total:
                    print("Resuming truncated " + filename + " at " + str(received) +
                          "/" + str(expected_total) + " bytes", flush=True)
                    continue
                actual = digest(temporary)
                if actual != item["sha256"]:
                    raise ValueError("SHA-256 mismatch for " + filename + ": " + actual)
                temporary.replace(final)
                print("Downloaded and verified " + filename, flush=True)
                return final
            except (OSError, TimeoutError) as error:
                if attempt == 5:
                    raise
                print("Resuming " + filename + ": " + str(error), flush=True)
                time.sleep(attempt + 1)
        raise RuntimeError("Download remained incomplete after six attempts: " + filename)
    finally:
        if temporary.exists():
            temporary.unlink()

def install(items, downloads, root):
    root.mkdir(parents=True, exist_ok=True)
    by_id = {item["id"]: item for item in items}
    for identity in ("node", "ghidra"):
        item = by_id[identity]
        destination = root / identity
        if destination.exists():
            raise ValueError("Refusing to replace existing installation: " + str(destination))
        with tempfile.TemporaryDirectory(prefix=identity + "-", dir=root) as stage:
            stage = Path(stage)
            path = downloads / item["filename"]
            if identity == "node":
                with tarfile.open(path, "r:xz") as archive:
                    archive.extractall(stage, filter="data")
            else:
                with zipfile.ZipFile(path) as archive:
                    for member in archive.infolist():
                        name = Path(member.filename)
                        if name.is_absolute() or ".." in name.parts:
                            raise ValueError("Unsafe archive path")
                        extracted = Path(archive.extract(member, stage))
                        mode = (member.external_attr >> 16) & 0o777
                        if mode and extracted.is_file():
                            extracted.chmod(mode)
            children = list(stage.iterdir())
            if len(children) != 1 or not children[0].is_dir():
                raise ValueError("Unexpected archive layout: " + identity)
            shutil.move(str(children[0]), destination)
    for identity in ("jadx", "apktool"):
        item = by_id[identity]
        directory = root / identity
        directory.mkdir(exist_ok=True)
        shutil.copy2(downloads / item["filename"], directory / item["filename"])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--only", help="Comma-separated artifact or fixture IDs")
    parser.add_argument("--install-root", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    selected = manifest["artifacts"]
    if args.only:
        requested = set(args.only.split(","))
        selected = [x for x in manifest["artifacts"] + manifest.get("fixtures", []) if x["id"] in requested]
        if {x["id"] for x in selected} != requested:
            raise ValueError("Unknown requested artifact ID")
    for item in selected:
        download(item, args.output)
    if args.install_root:
        install(selected, args.output, args.install_root)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
