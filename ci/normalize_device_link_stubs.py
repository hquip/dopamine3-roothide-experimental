#!/usr/bin/env python3
"""Convert exact official link metadata to explicit iOS-device TBD v4 targets."""

import argparse
import hashlib
import json
from pathlib import Path
import re


STUBS = {
    "libroothide.tbd": "c825e5f9d76a86c00b01c9c673986357ab109e1a4d8d9f74e3493eed35cef1a5",
    "Deps/liblzma/liblzma.5.tbd": "1bbcbddefdf92de7bab6a0ff735016a773e10a82f5078b77fcbca74ba5e1893b",
    "Deps/libzstd/libzstd.1.tbd": "53d6266a9b413ade0d7e86cf1ff34013e83353729f1b31cc13aca54992695e43",
    "Deps/liblz4/liblz4.1.tbd": "03c01034c382f2877e0851f33108b81e376b5c2c3a25ea1d302699c1354eb06a",
}
TARGETS = "[ arm64-ios, arm64e-ios ]"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def list_values(value):
    return tuple(part.strip().strip("'\"") for part in value.split(",") if part.strip())


def invariants(text):
    scalar = {}
    for key in ("install-name", "current-version", "compatibility-version"):
        matches = re.findall(r"^" + key + r":\s*(.+)$", text, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Expected exactly one scalar: " + key)
        scalar[key] = matches[0].strip().strip("'\"")
    flags = re.findall(r"^flags:\s*\[([^]]*)\]", text, re.MULTILINE)
    if len(flags) != 1:
        raise ValueError("Expected exactly one flags list")
    scalar["flags"] = list_values(flags[0])
    entries = re.findall(
        r"^    (symbols|objc-classes|objc-ivars|objc-eh-types|weak-def-symbols|weak-symbols|thread-local-symbols):\s*\[([^]]*)\]",
        text, re.MULTILINE,
    )
    if not entries:
        raise ValueError("Expected export entries")
    exports = {}
    for key, value in entries:
        key = "weak-symbols" if key == "weak-def-symbols" else key
        if key in exports:
            raise ValueError("Unexpected duplicate export field: " + key)
        exports[key] = list_values(value)
    scalar["exports"] = exports
    return scalar


def convert(relative, raw):
    if relative not in STUBS or sha256(raw) != STUBS[relative]:
        raise ValueError("Unexpected input stub path/hash: " + relative)
    text = raw.decode("utf-8")
    before = invariants(text)
    if not text.startswith("--- !tapi-tbd-v2\n"):
        raise ValueError("Expected the exact legacy TBD v2 document")
    text = text.replace("--- !tapi-tbd-v2\n", "--- !tapi-tbd\ntbd-version: 4\n", 1)
    text, count = re.subn(r"^platform:\s*ios\n", "", text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("Unexpected platform metadata")
    text, count = re.subn(
        r"^(\s*(?:- )?)archs:\s*\[[^]]*\]",
        lambda match: match.group(1) + "targets: " + TARGETS,
        text, flags=re.MULTILINE,
    )
    if count != 2:
        raise ValueError("Expected one document and one export architecture list")
    # The optional lz4 stub's sole UUID already names its iOS-device architecture.
    if relative == "Deps/liblz4/liblz4.1.tbd":
        text, count = re.subn(
            r"^uuids:\s*\[ 'arm64-ios: ([A-F0-9-]+)' \]\n",
            r"uuids:\n  - target: arm64-ios\n    value: \1\n",
            text, flags=re.MULTILINE,
        )
        if count != 1:
            raise ValueError("Unexpected lz4 UUID metadata")
    elif re.search(r"^uuids:", text, re.MULTILINE):
        raise ValueError("Unexpected UUID metadata")
    text = text.replace("    weak-def-symbols:", "    weak-symbols:")
    if invariants(text) != before:
        raise ValueError("A symbol, install name, version, or flag changed")
    if "archs:" in text or "platform:" in text:
        raise ValueError("Legacy platform metadata remained")
    if text.count("targets: " + TARGETS) != 2:
        raise ValueError("Explicit iOS-device target validation failed")
    return text.encode("utf-8"), before


def normalize(root, include_unlinked_lz4=False):
    root = Path(root).resolve(strict=True)
    project = (root / "Sileo.xcodeproj/project.pbxproj").read_text()
    records = []
    # Validate all inputs before modifying any runner file.
    prepared = []
    for relative in STUBS:
        path = root / relative
        if path.is_symlink() or root not in path.resolve(strict=True).parents:
            raise ValueError("Unexpected stub location: " + relative)
        raw = path.read_bytes()
        converted, preserved = convert(relative, raw)
        optional_lz4 = relative == "Deps/liblz4/liblz4.1.tbd"
        active = not optional_lz4 or include_unlinked_lz4 or "liblz4.1.tbd in Frameworks" in project
        record = {
            "path": relative,
            "input_sha256": sha256(raw),
            "output_sha256": sha256(converted) if active else sha256(raw),
            "targets": ["arm64-ios", "arm64e-ios"] if active else None,
            "preserved": preserved,
            "converted": active,
        }
        if not active:
            record["reason"] = "Referenced in the project but absent from the linked Frameworks build phase."
        records.append(record)
        if active:
            prepared.append((path, converted))
    for path, converted in prepared:
        path.write_bytes(converted)
    return records


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--include-unlinked-lz4", action="store_true")
    arguments = parser.parse_args()
    print(json.dumps(normalize(arguments.root, arguments.include_unlinked_lz4), indent=2))
