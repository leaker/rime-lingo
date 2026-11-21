#!/usr/bin/env python3
"""Writes latest.json, the manifest the updater trusts once it is signed.

Offline: reads one archive, writes one file. Usage:
    write-release-manifest.py <RimeLingo-VERSION.zip> <version> <build> <minimum-macos> <out-dir>
"""
import datetime
import hashlib
import json
import os
import re
import sys


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    archive, version, build, minimum, out = sys.argv[1:6]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        print(f"invalid version: {version}", file=sys.stderr)
        return 1
    if not re.fullmatch(r"[1-9]\d*", build):
        print(f"invalid build: {build}", file=sys.stderr)
        return 1
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", minimum):
        print(f"invalid minimum macOS version: {minimum}", file=sys.stderr)
        return 1
    name = os.path.basename(archive)
    if name != f"RimeLingo-{version}.zip":
        print(f"the archive must be named RimeLingo-{version}.zip, not {name}", file=sys.stderr)
        return 1
    digest = hashlib.sha256()
    with open(archive, "rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    manifest = {
        "product": "rimelingo",
        "version": version,
        "build": int(build),
        "date": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
        "minimumSystemVersion": minimum,
        "files": {"zip": {"name": name, "size": os.path.getsize(archive), "sha256": digest.hexdigest()}},
    }
    with open(os.path.join(out, "latest.json"), "w", encoding="utf-8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
