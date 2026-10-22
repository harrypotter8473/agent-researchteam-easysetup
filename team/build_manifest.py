#!/usr/bin/env python3
"""build_manifest.py [--check] — SHA-256 of every file the installer copies from team/.

The Windows installer refuses to install a payload whose files do not match manifest.json
(a partly extracted ZIP, a stray edit), the same way it pinned the old persona files. Run it
after changing anything under team/; tests fail while the manifest is stale.
"""
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKIP = {"manifest.json", "build_manifest.py"}


def files():
    for p in sorted(HERE.rglob("*")):
        rel = p.relative_to(HERE).as_posix()
        if p.is_file() and p.name not in SKIP and "__pycache__" not in rel and not p.name.startswith(".DS_Store"):
            yield rel, p


def build():
    return {"schema": 1, "files": {rel: hashlib.sha256(p.read_bytes()).hexdigest() for rel, p in files()}}


if __name__ == "__main__":
    want = json.dumps(build(), indent=1, sort_keys=True) + "\n"
    target = HERE / "manifest.json"
    if "--check" in sys.argv:
        have = target.read_text(encoding="utf-8") if target.exists() else ""
        if have != want:
            sys.exit("team/manifest.json is stale — run: python team/build_manifest.py")
        print("team/manifest.json is current")
    else:
        target.write_text(want, encoding="utf-8", newline="\n")
        print(f"wrote {target} ({len(build()['files'])} files)")
