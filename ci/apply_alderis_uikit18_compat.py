#!/usr/bin/env python3
"""Apply the two-line naming fix to the exact locked Alderis checkout only."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ALDERIS_REVISION = "95030bfc6afc5d58a22aaa013e0f4c77317b57a1"
SOURCE_RELATIVE = Path("Alderis/ColorPickerInnerViewController.swift")
BEFORE_SHA256 = "6f361b069a2d02fa72967dc94697e761757a6f4f17358d3f018b130e864aaa4b"
AFTER_SHA256 = "3dd770f1420bdd19799dddcf2280793afabffef66571d538f62b59afcc29f3d9"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply(checkout):
    checkout = Path(checkout).resolve(strict=True)
    revision = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != ALDERIS_REVISION:
        raise RuntimeError("Unexpected Alderis revision; refusing the compatibility patch.")

    source = checkout / SOURCE_RELATIVE
    if digest(source) != BEFORE_SHA256:
        raise RuntimeError("Unexpected Alderis source hash; refusing the compatibility patch.")
    patch = Path(__file__).resolve().parent / "patches/alderis-uikit18-tab-name.patch"
    subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-C", str(checkout), "apply", "--check", str(patch)], check=True
    )
    subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-C", str(checkout), "apply", str(patch)], check=True
    )
    if digest(source) != AFTER_SHA256:
        raise RuntimeError("Alderis compatibility patch produced an unexpected source hash.")

    print(json.dumps({
        "dependency": "Alderis",
        "locked_revision": revision,
        "source": SOURCE_RELATIVE.as_posix(),
        "source_before_sha256": BEFORE_SHA256,
        "source_after_sha256": AFTER_SHA256,
        "patch": patch.name,
        "patch_sha256": digest(patch),
        "reason": "Rename an internal color-picker field conflicting with UIKit 18 UIViewController.tab.",
    }, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: apply_alderis_uikit18_compat.py <locked Alderis checkout>")
    apply(sys.argv[1])
