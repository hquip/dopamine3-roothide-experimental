#!/usr/bin/env python3
"""Exercise runtime failure handling, compiling the actual production helpers.

XPC and persona RPCs are fault-injected; no iOS tool or exploit is executed.
macOS also exercises actual killed-child reaping through libdispatch.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def function(path: str, name: str) -> str:
    source = (ROOT / path).read_text(encoding="utf-8")
    anchor = source.index(name + "(")
    start = source.rfind("\n", 0, anchor) + 1
    brace = source.index("{", anchor)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


ROOT_TEST = r'''
#ifdef _WIN32
#define _WIN32_WINNT 0x0600
#endif
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
typedef SRWLOCK pthread_mutex_t;
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define pthread_mutex_lock AcquireSRWLockExclusive
#define pthread_mutex_unlock ReleaseSRWLockExclusive
#define THREAD_RESULT DWORD WINAPI
#define THREAD_RETURN return 0
#else
#include <pthread.h>
#define THREAD_RESULT void *
#define THREAD_RETURN return NULL
#endif
#ifndef PATH_MAX
#define PATH_MAX 1024
#endif
#define JBS_DOMAIN_SYSTEMWIDE 1
#define JBS_SYSTEMWIDE_GET_JBROOT 1
#define XPC_TYPE_DICTIONARY 1
typedef struct { int type; const char *path; } reply_t;
typedef reply_t *xpc_object_t;
static reply_t empty = {1, ""}, bare = {1, "/"}, relative = {1, "relative"};
static reply_t wrongType = {2, "ignored"}, valid = {1, "/private/var/.jbroot-test"};
static char oversized[PATH_MAX + 1];
static reply_t tooLong = {1, oversized};
static _Atomic int requests;
static int mode;
char *jbclient_get_jbroot(void);
static xpc_object_t jbserver_xpc_send(int domain, int action, void *unused) {
    (void)domain; (void)action; (void)unused;
    int count = atomic_fetch_add(&requests, 1);
    if (mode == 0) {
        xpc_object_t sequence[] = {NULL, &empty, &bare, &relative, &tooLong, &wrongType, &valid};
        assert(count < 7);
        return sequence[count];
    }
    if (mode == 2 && count == 0) {
        assert(jbclient_get_jbroot() != NULL);
        return NULL;
    }
    return &valid;
}
static int xpc_get_type(xpc_object_t reply) { return reply->type; }
static const char *xpc_dictionary_get_string(xpc_object_t reply, const char *key) {
    assert(strcmp(key, "root-path") == 0); return reply->path;
}
static void xpc_release(xpc_object_t reply) { (void)reply; }
#define strlcpy test_strlcpy
static size_t strlcpy(char *to, const char *from, size_t limit) {
    size_t length = strlen(from);
    if (limit) { size_t n = length < limit - 1 ? length : limit - 1; memcpy(to, from, n); to[n] = 0; }
    return length;
}
@FUNCTION@
static THREAD_RESULT root_reader(void *unused) {
    (void)unused;
    for (int i = 0; i < 10000; i++) {
        const char *path = jbclient_get_jbroot();
        assert(path && strcmp(path, valid.path) == 0);
    }
    THREAD_RETURN;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    mode = atoi(argv[1]);
    memset(oversized, 'x', sizeof(oversized)); oversized[0] = '/'; oversized[PATH_MAX] = 0;
    if (mode == 0) {
        for (int i = 0; i < 6; i++) assert(jbclient_get_jbroot() == NULL);
        char *path = jbclient_get_jbroot();
        assert(path && strcmp(path, valid.path) == 0);
        for (int i = 0; i < 1000; i++) assert(jbclient_get_jbroot() == path);
        assert(atomic_load(&requests) == 7);
    } else if (mode == 1) {
#ifdef _WIN32
        HANDLE threads[8];
        for (int i = 0; i < 8; i++) { threads[i] = CreateThread(NULL, 0, root_reader, NULL, 0, NULL); assert(threads[i]); }
        assert(WaitForMultipleObjects(8, threads, TRUE, 10000) == WAIT_OBJECT_0);
        for (int i = 0; i < 8; i++) CloseHandle(threads[i]);
#else
        pthread_t threads[8];
        for (int i = 0; i < 8; i++) assert(pthread_create(&threads[i], NULL, root_reader, NULL) == 0);
        for (int i = 0; i < 8; i++) assert(pthread_join(threads[i], NULL) == 0);
#endif
        assert(atomic_load(&requests) >= 1 && atomic_load(&requests) <= 8);
    } else {
        assert(mode == 2);
        const char *path = jbclient_get_jbroot();
        assert(path && strcmp(path, valid.path) == 0 && atomic_load(&requests) == 2);
    }
    puts("PASS root cache");
    return 0;
}
'''

PERSONA_TEST = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
typedef int pid_t;
typedef struct { short flags; } attributes_t;
typedef attributes_t *posix_spawnattr_t;
struct _posix_spawn_persona_info { int pspi_uid, pspi_gid; };
static int fixes, resumes, cleanups, fixResult, resumeError, attributeWrites;
static int infoCalls, infoLength = 56;
static uint64_t infoUniqueID = 999;
static int proc_pidinfo(pid_t pid, int flavor, uint64_t arg, void *buffer, int size) {
    assert(pid > 0 && flavor == 17 && arg == 1 && size == 56);
    infoCalls++;
    memset(buffer, 0, size); memcpy((char *)buffer + 16, &infoUniqueID, sizeof(infoUniqueID));
    return infoLength;
}
static int jbclient_persona_fix(pid_t pid, int uid, int gid) {
    assert(pid > 0 && (uid == 0 || gid == 0)); fixes++; return fixResult;
}
static int test_kill(pid_t pid, int signal) {
    assert(pid > 0 && signal == 18); resumes++; errno = resumeError; return resumeError ? -1 : 0;
}
#define SIGCONT 18
#define kill test_kill
static void roothide_kill_and_reap_child(pid_t pid) { assert(pid > 0); cleanups++; }
static int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags) {
    assert(attr && *attr); (*attr)->flags = flags; attributeWrites++; return 0;
}
@FUNCTIONS@
static void reset(void) { fixes = resumes = cleanups = fixResult = resumeError = attributeWrites = 0; }
int main(void) {
    reset(); assert(finish_persona_spawn(5, -1, 0, -1, true) == 5);
    assert(fixes == 0 && resumes == 0 && cleanups == 0);
    assert(finish_persona_spawn(0, -1, 0, -1, true) == ECHILD);
    assert(finish_persona_spawn(0, 0, 0, -1, true) == ECHILD);
    assert(fixes == 0 && resumes == 0 && cleanups == 0);
    assert(finish_persona_spawn(0, 17, 501, 501, true) == 0);
    assert(fixes == 0);
    reset(); assert(finish_persona_spawn(0, 17, 0, -1, true) == 0);
    assert(fixes == 1 && resumes == 1 && cleanups == 0);
    reset(); assert(finish_persona_spawn(0, 17, 501, 0, false) == 0);
    assert(fixes == 1 && resumes == 0 && cleanups == 0);
    reset(); fixResult = -1;
    assert(finish_persona_spawn(0, 17, 0, 0, true) == EIO);
    assert(fixes == 1 && resumes == 0 && cleanups == 1);
    reset(); resumeError = ESRCH;
    assert(finish_persona_spawn(0, 17, 0, 0, true) == ESRCH);
    assert(fixes == 1 && resumes == 1 && cleanups == 1);
    reset(); attributes_t storage = {0x80}; posix_spawnattr_t attr = &storage;
    struct _posix_spawn_persona_info info = {501, 501};
    restore_persona_spawn_attributes(&attr, &info, 0, -1, 0);
    assert(info.pspi_uid == 0 && info.pspi_gid == 501 && storage.flags == 0);
    info.pspi_uid = 501; info.pspi_gid = 501; storage.flags = 0x80;
    restore_persona_spawn_attributes(&attr, &info, 501, 0, 0x80);
    assert(info.pspi_uid == 501 && info.pspi_gid == 0 && storage.flags == 0x80);
    int previousWrites = attributeWrites;
    restore_persona_spawn_attributes(&attr, NULL, 0, 0, 0);
    assert(attributeWrites == previousWrites);
    assert(child_patch_identity_matches(1, 42, 1, 100, 100));
    assert(!child_patch_identity_matches(1, 42, 1, 100, 101)); // reused PID
    assert(!child_patch_identity_matches(1, 42, 1, 0, 0)); // no identity
    assert(!child_patch_identity_matches(1, 42, 2, 100, 100)); // other parent
    assert(!child_patch_identity_matches(1, 0, 1, 100, 100));
    assert(!child_patch_identity_matches(0, 42, 0, 100, 100));
    assert(roothide_process_unique_id(42) == 999);
    infoLength = 55; assert(roothide_process_unique_id(42) == 0);
    infoLength = -1; assert(roothide_process_unique_id(42) == 0);
    int previousInfoCalls = infoCalls;
    assert(roothide_process_unique_id(0) == 0 && roothide_process_unique_id(-1) == 0);
    assert(infoCalls == previousInfoCalls);
    puts("PASS persona failures, attribute restoration, stale child identity");
    return 0;
}
'''

CLEANUP_FAILURE_TEST = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
typedef int pid_t;
#define SIGKILL 9
#define WNOHANG 1
static int waits, kills, scheduled, killError;
static int replies[8], errors[8];
static uint64_t uniqueID = 999;
static pid_t test_waitpid(pid_t pid, void *status, int flags) {
    assert(pid > 0 && !status && flags == WNOHANG && waits < 8);
    errno = errors[waits]; return replies[waits++];
}
static int test_kill(pid_t pid, int sig) {
    assert(pid > 0 && sig == SIGKILL); kills++; errno = killError; return killError ? -1 : 0;
}
static uint64_t roothide_process_unique_id(pid_t pid) { assert(pid > 0); return uniqueID; }
#define waitpid test_waitpid
#define kill test_kill
// The real delayed-reaping block is exercised by the macOS test below.
#define dispatch_async(queue, block) (scheduled++)
@FUNCTION@
static void reset(void) {
    waits = kills = scheduled = killError = 0; uniqueID = 999;
    for (int i = 0; i < 8; i++) replies[i] = errors[i] = 0;
    errno = EINVAL;
}
int main(void) {
    reset(); roothide_kill_and_reap_child(0); roothide_kill_and_reap_child(-1);
    assert(waits == 0 && kills == 0 && scheduled == 0);
    reset(); replies[0] = 42; roothide_kill_and_reap_child(42);
    assert(waits == 1 && kills == 0 && scheduled == 0 && errno == EINVAL);
    reset(); replies[0] = -1; errors[0] = ECHILD; roothide_kill_and_reap_child(42);
    assert(waits == 1 && kills == 0 && scheduled == 0 && errno == EINVAL);
    reset(); replies[1] = 42; roothide_kill_and_reap_child(42);
    assert(waits == 2 && kills == 1 && scheduled == 0 && errno == EINVAL);
    reset(); roothide_kill_and_reap_child(42);
    assert(waits == 2 && kills == 1 && scheduled == 1 && errno == EINVAL);
    reset(); killError = EPERM; roothide_kill_and_reap_child(42);
    assert(waits == 1 && kills == 1 && scheduled == 0 && errno == EINVAL);
    reset(); replies[0] = -1; errors[0] = EINTR; replies[2] = 42;
    roothide_kill_and_reap_child(42);
    assert(waits == 3 && kills == 1 && scheduled == 0 && errno == EINVAL);
    reset(); uniqueID = 0; roothide_kill_and_reap_child(42);
    assert(waits == 2 && kills == 1 && scheduled == 0 && errno == EINVAL);
    puts("PASS cleanup ownership, already reaped, interrupted wait, signal failure");
    return 0;
}
'''

CLEANUP_TEST = r'''
#include <assert.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdio.h>
#include <time.h>
#include "roothider/spawn_cleanup.h"
int main(void) {
    roothide_kill_and_reap_child(0);
    roothide_kill_and_reap_child(-1);
    pid_t pid = fork(); assert(pid >= 0);
    if (!pid) { for (;;) pause(); }
    errno = EINVAL;
    roothide_kill_and_reap_child(pid);
    assert(errno == EINVAL);
    struct timespec delay = {0, 10000000};
    bool reaped = false;
    for (int i = 0; i < 250; i++) {
        if (kill(pid, 0) == -1 && errno == ESRCH) { reaped = true; break; }
        nanosleep(&delay, NULL);
    }
    assert(reaped);
    pid = fork(); assert(pid >= 0);
    if (!pid) _exit(0);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {}
    errno = EINVAL;
    roothide_kill_and_reap_child(pid); // already reaped: no stale signal
    assert(errno == EINVAL);
    puts("PASS actual child kill/reap");
    return 0;
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    args = parser.parse_args()
    if not args.clang:
        raise SystemExit("clang is required")
    with tempfile.TemporaryDirectory(prefix="roothide-runtime-tests-") as directory:
        output = Path(directory)

        def build_and_run(name: str, source: str, cases: list[str] | None = None, *, blocks: bool = False) -> None:
            cfile = output / (name + ".c")
            binary = output / (name + (".exe" if os.name == "nt" else ""))
            cfile.write_text(source, encoding="utf-8")
            command = [args.clang, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", str(cfile), "-o", str(binary)]
            if os.name != "nt":
                command.append("-pthread")
            if blocks:
                command += ["-fblocks", "-I", str(ROOT / "BaseBin/libjailbreak/src")]
            subprocess.run(command, check=True, timeout=60)
            for case in cases if cases is not None else [None]:
                subprocess.run([str(binary)] + ([] if case is None else [case]), check=True, timeout=15)

        root = function("BaseBin/libjailbreak/src/jbclient_xpc.c", "jbclient_get_jbroot")
        build_and_run("root_cache", ROOT_TEST.replace("@FUNCTION@", root), ["0", "1", "2"])
        common = "BaseBin/systemhook/src/common/common.c"
        helpers = function(common, "restore_persona_spawn_attributes") + function(common, "finish_persona_spawn")
        helpers += function("BaseBin/jailbreakd/src/server.m", "child_patch_identity_matches")
        helpers += function("BaseBin/libjailbreak/src/roothider/process_identity.h", "roothide_process_unique_id")
        build_and_run("persona_and_identity", PERSONA_TEST.replace("@FUNCTIONS@", helpers))
        cleanup = function("BaseBin/libjailbreak/src/roothider/spawn_cleanup.h", "roothide_kill_and_reap_child")
        build_and_run("cleanup_failures", CLEANUP_FAILURE_TEST.replace("@FUNCTION@", cleanup))
        if sys.platform == "darwin":
            build_and_run("spawn_cleanup", CLEANUP_TEST, blocks=True)
        else:
            print("SKIP actual Darwin child cleanup on this host (covered on macOS CI)")


if __name__ == "__main__":
    main()
