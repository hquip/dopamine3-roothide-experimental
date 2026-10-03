#!/usr/bin/env python3
"""Compile the app's actual ordinary-cache helper and exercise macOS filesystems."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).resolve().parents[1] / "Sileo/Backend/Dependency Resolver/DependencyResolverAccelerator.swift"
TESTS = Path(__file__).with_name("installation_operations_cache_tests.swift")
BEGIN = "// BEGIN INSTALLATION OPERATIONS CACHE HELPER"
END = "// END INSTALLATION OPERATIONS CACHE HELPER"


def main():
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        raise SystemExit("Expected exactly one shared app cache helper.")
    helper = source.split(BEGIN, 1)[1].split(END, 1)[0]
    if sys.platform != "darwin":
        raise SystemExit("This test requires macOS Swift Foundation; it does not substitute a mock filesystem.")
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="sileo-operations-foundation-") as temporary:
        temporary = Path(temporary)
        helper_path = temporary / "InstallationOperationsCache.swift"
        tests_path = temporary / "main.swift"
        executable = temporary / "operations-cache-test"
        helper_path.write_text("import Foundation\n" + helper, encoding="utf-8")
        tests_path.write_text(TESTS.read_text(encoding="utf-8"), encoding="utf-8")
        subprocess.run([swiftc, "-warnings-as-errors", str(helper_path), str(tests_path),
                        "-o", str(executable)], check=True)
        result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
        # The executable emits one JSON result with named, independently exercised cases.
        report = json.loads(result.stdout)
        if report.get("status") != "passed":
            raise SystemExit("Foundation filesystem tests did not report success.")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
