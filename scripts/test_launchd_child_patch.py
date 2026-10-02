#!/usr/bin/env python3
"""Test production launchd child-patch policy and credential-helper composition.

Compiles the actual production policy, dispatcher and helper preparation
functions. Kernel, process and dyld operations are fault-injected. This checks
who owns a suspended child's patch; it does not execute an iOS loader.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract_function(path: str, name: str) -> str:
    source = (ROOT / path).read_text(encoding="utf-8")
    anchor = source.index(name + "(")
    start = source.rfind("\n", 0, anchor) + 1
    brace = source.index("{", anchor)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#define PATH_MAX 1024
#define SIGCONT 18
#define CS_GET_TASK_ALLOW 4
typedef int pid_t;

static bool globalDyld, forcedDyld, childExists;
static int parentPid, csCalls, dyldCalls, resumes, identityCalls;
static int csResult, dyldResult, resumeError, identityChangesAfter;
static uint64_t uniqueID;
static int allowInvalidCalls, syscallCalls, filterCalls, csSetCalls;

static int proc_get_ppid(pid_t pid) { assert(pid > 0); return parentPid; }
static uint64_t proc_get_uniqueid(pid_t pid) {
    assert(pid > 0);
    identityCalls++;
    return identityChangesAfter && identityCalls > identityChangesAfter ? 1001 : uniqueID;
}
static bool dyld_patch_enabled(void) { return globalDyld; }
static char *proc_get_path(pid_t pid, char *buffer) {
    assert(pid > 0); buffer[0] = '/'; buffer[1] = 0; return buffer;
}
static bool process_force_dyld_patch(const char *path, const char **argv) {
    assert(path && path[0] == '/' && !argv); return forcedDyld;
}
static int proc_patch_dyld(pid_t pid) { assert(pid > 0); dyldCalls++; return dyldResult; }
static int proc_patch_csflags(pid_t pid) { assert(pid > 0); csCalls++; return csResult; }
static int test_kill(pid_t pid, int signal) {
    assert(pid > 0 && signal == SIGCONT); resumes++; errno = resumeError;
    return resumeError ? -1 : 0;
}
#define kill test_kill
static uint64_t proc_find(pid_t pid) { assert(pid > 0); return childExists ? 0x1234 : 0; }
static void cs_allow_invalid(uint64_t proc, bool fully) {
    assert(proc == 0x1234 && !fully); allowInvalidCalls++;
}
static void proc_csflags_set(uint64_t proc, int flags) {
    assert(proc == 0x1234 && flags == CS_GET_TASK_ALLOW); csSetCalls++;
}
static void proc_allow_all_syscalls(uint64_t proc) { assert(proc == 0x1234); syscallCalls++; }
static void proc_remove_msg_filter(uint64_t proc) { assert(proc == 0x1234); filterCalls++; }

@FUNCTIONS@

static void reset(void) {
    globalDyld = forcedDyld = false; childExists = true;
    parentPid = 1; uniqueID = 1000;
    csCalls = dyldCalls = resumes = identityCalls = 0;
    csResult = dyldResult = resumeError = identityChangesAfter = 0;
    allowInvalidCalls = syscallCalls = filterCalls = csSetCalls = 0;
}

int main(void) {
    // Caller-suspended children retain the original server policy, even if
    // global or per-executable configuration would normally patch dyld.
    for (int global = 0; global <= 1; global++) {
        for (int forced = 0; forced <= 1; forced++) {
            reset(); globalDyld = global; forcedDyld = forced;
            assert(roothide_launchd_patch_child(42, false) == 0);
            assert(csCalls == 1 && dyldCalls == 0 && resumes == 0);
            // Actual credential_helper_patch then owns the only dyld patch.
            assert(credential_helper_patch(42, NULL) == 0);
            assert(dyldCalls == 1 && csCalls == 1 && resumes == 0);
            assert(allowInvalidCalls == 1 && syscallCalls == 1);
            assert(filterCalls == 1 && csSetCalls == 1);

            reset(); globalDyld = global; forcedDyld = forced;
            assert(roothide_launchd_patch_child(42, true) == 0);
            assert(resumes == 1);
            assert(dyldCalls == ((global || forced) ? 1 : 0));
            assert(csCalls == ((global || forced) ? 0 : 1));
        }
    }
    reset(); assert(roothide_launchd_patch_child(0, true) == EPERM);
    assert(roothide_launchd_patch_child(-1, false) == EPERM);
    assert(csCalls == 0 && dyldCalls == 0 && resumes == 0);
    reset(); parentPid = 20;
    assert(roothide_launchd_patch_child(42, true) == EPERM);
    assert(identityCalls == 0 && csCalls == 0 && dyldCalls == 0 && resumes == 0);
    reset(); uniqueID = 0;
    assert(roothide_launchd_patch_child(42, true) == ESRCH);
    assert(csCalls == 0 && dyldCalls == 0 && resumes == 0);
    reset(); csResult = EACCES;
    assert(roothide_launchd_patch_child(42, false) == EACCES);
    assert(csCalls == 1 && dyldCalls == 0 && resumes == 0);
    reset(); csResult = EACCES;
    assert(roothide_launchd_patch_child(42, true) == EACCES);
    assert(csCalls == 1 && dyldCalls == 0 && resumes == 0);
    reset(); globalDyld = true; dyldResult = EIO;
    assert(roothide_launchd_patch_child(42, true) == EIO);
    assert(csCalls == 0 && dyldCalls == 1 && resumes == 0);
    for (int resume = 0; resume <= 1; resume++) {
        reset(); globalDyld = true; identityChangesAfter = 1;
        assert(roothide_launchd_patch_child(42, resume) == ESRCH);
        assert(resumes == 0);
    }
    reset(); resumeError = ESRCH;
    assert(roothide_launchd_patch_child(42, true) == ESRCH);
    assert(resumes == 1);
    reset(); childExists = false;
    assert(credential_helper_patch(42, NULL) == ESRCH);
    assert(dyldCalls == 0 && csSetCalls == 0);
    reset(); dyldResult = -1;
    assert(credential_helper_patch(42, NULL) == EIO);
    assert(dyldCalls == 1);
    puts("PASS launchd suspended-child policy, helper single dyld patch, failures and identity checks");
    return 0;
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default=shutil.which("clang") or shutil.which("gcc"))
    args = parser.parse_args()
    if not args.cc:
        raise SystemExit("clang or gcc is required")
    functions = extract_function("BaseBin/libjailbreak/src/roothider/common.m", "roothide_patch_proc")
    functions += "\n" + extract_function("BaseBin/launchdhook/src/roothider.m", "roothide_launchd_patch_child")
    functions += "\n" + extract_function("BaseBin/libjailbreak/src/util.c", "credential_helper_patch")
    with tempfile.TemporaryDirectory(prefix="roothide-launchd-policy-") as directory:
        cfile = Path(directory) / "test.c"
        binary = Path(directory) / ("test.exe" if os.name == "nt" else "test")
        cfile.write_text(HARNESS.replace("@FUNCTIONS@", functions), encoding="utf-8")
        subprocess.run([args.cc, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                        str(cfile), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
