#!/usr/bin/env python3
"""Native macOS regression for ordinary APT-wrapper descriptor actions only.

Compiles a self-spawn probe and exercises descriptor layouts which alias outputs
5 or 6. Does not run APT, installation commands, identity/persona attributes,
RootHide mapping, jailbreak code, device services, or any privileged helper.
The successful repair prototype is not a diagnosis of the device's EIO error.
"""

from pathlib import Path
import errno
import hashlib
import json
import re
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).resolve().parents[1] / "Sileo/Backend/APT Wrapper/APTWrapper.swift"
PROBE = Path(__file__).with_name("apt_pipe_actions_probe.c")
EXPECTED_BASELINE = [
    "posix_spawn_file_actions_init(&fileActions)",
    "posix_spawn_file_actions_addclose(&fileActions, pipestdout[0])",
    "posix_spawn_file_actions_addclose(&fileActions, pipestderr[0])",
    "posix_spawn_file_actions_addclose(&fileActions, pipestatusfd[0])",
    "posix_spawn_file_actions_addclose(&fileActions, pipesileo[0])",
    "posix_spawn_file_actions_adddup2(&fileActions, pipestdout[1], STDOUT_FILENO)",
    "posix_spawn_file_actions_adddup2(&fileActions, pipestderr[1], STDERR_FILENO)",
    "posix_spawn_file_actions_adddup2(&fileActions, pipestatusfd[1], 5)",
    "posix_spawn_file_actions_adddup2(&fileActions, pipesileo[1], Int32(sileoFD))",
    "posix_spawn_file_actions_addclose(&fileActions, pipestdout[1])",
    "posix_spawn_file_actions_addclose(&fileActions, pipestderr[1])",
    "posix_spawn_file_actions_addclose(&fileActions, pipestatusfd[1])",
    "posix_spawn_file_actions_addclose(&fileActions, pipesileo[1])",
]


def assert_case(case, first_fd, relocated, invalid_action):
    assert case["first_pipe_fd"] == first_fd
    assert case["relocated"] == relocated
    assert case["invalid_action"] == invalid_action
    assert case["initial_open_fds"] == case["final_open_fds"] == 3, case
    expected_layout = [[first_fd + channel * 2, first_fd + channel * 2 + 1]
                       for channel in range(4)]
    assert case["original_pipe_fds"] == expected_layout, case
    if invalid_action:
        assert case["setup_error"] == errno.EBADF, case
        assert case["failed_stage"] == "add output duplication action", case
        assert case["spawn_status"] == case["child_exit"] == -1, case
        return
    assert case["setup_error"] == case["spawn_status"] == 0, case
    expected_channels = [True, True, True, True]
    if not relocated:
        if first_fd in (3, 5):
            expected_channels[3] = False
        elif first_fd == 4:
            expected_channels[2] = False
    assert case["channels_received"] == expected_channels, case
    expected_exit = sum(1 << index for index, present in enumerate(expected_channels) if not present)
    assert case["child_exit"] == expected_exit, case


def main():
    source = SOURCE.read_text(encoding="utf-8")
    # Verify this reference test represents the app's current action order.
    actual_actions = re.findall(r"^\s*(posix_spawn_file_actions_(?:init|addclose|adddup2)\(.*)\s*$",
                                source, flags=re.MULTILINE)
    actual_actions = [action.strip() for action in actual_actions]
    if actual_actions != EXPECTED_BASELINE:
        raise SystemExit("App file-action sequence differs from the audited baseline; update the regression explicitly.")
    if not re.search(r"let\s+sileoFD\s*=\s*6\b", source):
        raise SystemExit("Expected protocol output descriptor 6 in audited baseline.")
    if sys.platform != "darwin":
        raise SystemExit("Requires native macOS POSIX spawn; mock or cross-compiled execution is not a substitute.")

    compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    cases = []
    with tempfile.TemporaryDirectory(prefix="sileo-ordinary-pipe-regression-") as temporary:
        executable = Path(temporary) / "pipe-probe"
        subprocess.run([compiler, "-isysroot", sdk, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        str(PROBE), "-o", str(executable)], check=True)
        for first_fd in (3, 4, 5, 6, 7, 64):
            for relocated in (False, True):
                result = subprocess.run([str(executable), str(first_fd),
                                         "relocated" if relocated else "original", "valid-actions"],
                                        check=True, capture_output=True, text=True, timeout=15,
                                        close_fds=True)
                case = json.loads(result.stdout)
                assert_case(case, first_fd, relocated, False)
                cases.append(case)
        result = subprocess.run([str(executable), "3", "relocated", "invalid-action"],
                                check=True, capture_output=True, text=True, timeout=15,
                                close_fds=True)
        case = json.loads(result.stdout)
        assert_case(case, 3, True, True)
        cases.append(case)
    print(json.dumps({
        "status": "passed",
        "scope": "unprivileged self-spawn ordinary POSIX I/O only",
        "baseline_action_sha256": hashlib.sha256("\n".join(actual_actions).encode()).hexdigest(),
        "baseline_low_fd_collision_reproduced": True,
        "relocated_pipe_prototype_all_channels_passed": True,
        "checked_action_failure_preserves_resource_count": True,
        "device_EIO_cause_established": False,
        "cases": cases,
    }, indent=2))


if __name__ == "__main__":
    main()
