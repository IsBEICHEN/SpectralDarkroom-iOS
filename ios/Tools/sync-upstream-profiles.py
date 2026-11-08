#!/usr/bin/env python3
"""Copy missing measured profiles from SpektraLab's published resource catalogue.

The index is downloaded separately so its Git blob SHA is used to verify each
file. Existing files are left untouched. This is a maintainer-only sync tool.
"""

import hashlib
import json
import pathlib
import subprocess
import sys

index = json.loads(pathlib.Path(sys.argv[1]).read_text())
destination = pathlib.Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)

for item in index:
    name = item["name"]
    if item["type"] != "file" or not name.endswith(".json") or "/" in name:
        raise ValueError(f"unexpected profile entry: {name}")
    target = destination / name
    if target.exists():
        data = target.read_bytes()
    else:
        subprocess.run(
            ["curl", "-fsSL", "--retry", "3", "--max-time", "45",
             "-H", "Accept: application/vnd.github.raw+json",
             "-o", str(target), item["url"]],
            check=True,
        )
        data = target.read_bytes()
    digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if digest != item["sha"]:
        if target.exists():
            target.unlink()
        raise ValueError(f"profile checksum mismatch: {name}")
    json.loads(data)
    print(name, flush=True)
