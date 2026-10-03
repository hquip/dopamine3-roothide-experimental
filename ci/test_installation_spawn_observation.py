#!/usr/bin/env python3
"""Native Swift tests of optional diagnostic display only; no real spawn or RPC.

Extracts the actual app helper, imports the same C ABI header, and discovers a
plain thread-local C mock through the ordinary Darwin dynamic loader. Missing
API, ABI mismatches, invalid/absent fields, signed INT64 and unknown stages are
tested without inferring the device's real installation failure cause.
"""

from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sileo/Backend/APT Wrapper/APTWrapper.swift"
HEADER = ROOT / "Sileo/Backend/C Contrib/jbclient_persona_diagnostic.h"
MOCK = Path(__file__).with_name("persona_diagnostic_mock.c")
SWIFT_TESTS = Path(__file__).with_name("installation_spawn_observation_tests.swift")
BEGIN = "// BEGIN INSTALLATION SPAWN OBSERVATION HELPER"
END = "// END INSTALLATION SPAWN OBSERVATION HELPER"


def main():
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        raise SystemExit("Expected exactly one actual spawn observation helper.")
    helper = source.split(BEGIN, 1)[1].split(END, 1)[0]
    # Freeze the actual launch arguments: diagnostics cannot replace or retry
    # either of the existing persona/legacy branches.
    branches = (
        "posix_spawn(&pid, command, &pipeIO.fileActions, &attr, argv + [nil], env + [nil])",
        "posix_spawn(&pid, giveMeRootPath, &pipeIO.fileActions, nil, argv + [nil], env + [nil])",
    )
    for call in branches:
        expected = "spawnObservation.clearBeforeSpawn()\n                spawnStatus = " + call + "\n                spawnFailureDescription = spawnStatus != 0 ? spawnObservation.copyFailureDescription() : nil"
        if source.count(expected) != 1:
            raise SystemExit("Observation must surround exactly the original same-thread spawn call.")
    if "posix_spawn(" in helper or "xpc_" in helper or "spawnAsRoot" in helper:
        raise SystemExit("Display helper must not start commands or send RPC.")
    failure = source.split("if spawnStatus != 0 {", 1)[1].split("pipeIO.closeWriteEnds()", 1)[0]
    if not failure.index("Unable to start installation command") < failure.index("outputCallback(diagnostic") < failure.index("completionCallback"):
        raise SystemExit("Preserve existing stderr before failure completion ordering.")
    if "--source-only" in sys.argv:
        print(json.dumps({"status": "passed", "scope": "source invariants only", "native_tests_run": False}))
        return
    if sys.platform != "darwin":
        raise SystemExit("Requires native macOS Swift and Darwin dynamic-loader testing.")
    compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    reports = []
    with tempfile.TemporaryDirectory(prefix="sileo-observation-only-") as temporary:
        temporary = Path(temporary)
        swift_source = temporary / "main.swift"
        swift_source.write_text("import Foundation\nimport Darwin\n" + helper + "\n" + SWIFT_TESTS.read_text(encoding="utf-8"), encoding="utf-8")
        executable = temporary / "test-observation"
        subprocess.run([swiftc, "-sdk", sdk, "-swift-version", "5", "-warnings-as-errors", "-import-objc-header", str(HEADER), str(swift_source), "-o", str(executable)], check=True)
        for mode, define in (("complete-api", None), ("missing-clear", "OMIT_CLEAR"), ("missing-copy", "OMIT_COPY"), ("missing-api", None)):
            library = temporary / (mode + ".dylib")
            if mode != "missing-api":
                command = [compiler, "-isysroot", sdk, "-std=c11", "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(MOCK), "-o", str(library)]
                if define:
                    command.append("-D" + define)
                subprocess.run(command, check=True)
            result = subprocess.run([str(executable), mode, str(library)], check=True, capture_output=True, text=True, timeout=15)
            report = json.loads(result.stdout)
            if report.get("status") != "passed":
                raise SystemExit("Actual app observation display regression failed.")
            reports.append(report)
    print(json.dumps({"status": "passed", "scope": "optional observation display; mock data only", "actual_app_helper_sha256": hashlib.sha256(helper.encode()).hexdigest(), "c_abi_header_sha256": hashlib.sha256(HEADER.read_bytes()).hexdigest(), "device_failure_cause_established": False, "modes": reports}, indent=2))


if __name__ == "__main__":
    main()
