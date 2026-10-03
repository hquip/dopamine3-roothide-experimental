#!/usr/bin/env python3
"""Check the observation's source using two real dylibs/shared libraries.

Links the production passive helper into both libraries, as the runtime does.
Only the wrapper-image fixture exports its getters. These tests perform no
process spawning, persona RPC, entitlement query, credential, or kernel work.
Each loading order runs in a fresh host process so RTLD_DEFAULT cannot retain
symbols from the previous test. Test artifacts are retained, never removed.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "BaseBin/libjailbreak/src/jbclient_persona_diagnostic.c"
INCLUDE = HELPER.parent

LIBRARY = r'''
#include "jb_persona_diagnostic_internal.h"
#include <errno.h>

/* Only these two inert fixture functions are additionally exported. */
void fixture_publish(int64_t value) {
    jbclient_persona_diagnostic_v1 record = {
        .version = JBCLIENT_PERSONA_DIAGNOSTIC_VERSION,
        .size = JBCLIENT_PERSONA_DIAGNOSTIC_SIZE,
        .request_observed = 1,
        .original_result = value,
        .result_valid = 1,
    };
    jbclient_persona_diagnostic_publish(&record);
}
int fixture_local_copy(jbclient_persona_diagnostic_v1 *record) {
    return jbclient_persona_diagnostic_copy(record, sizeof(*record));
}
'''

LOADER = r'''
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "jbclient_persona_diagnostic.h"
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*clear_fn)(void);
typedef int (*copy_fn)(jbclient_persona_diagnostic_v1 *, uint32_t);
typedef void (*publish_fn)(int64_t);
typedef int (*local_copy_fn)(jbclient_persona_diagnostic_v1 *);
static clear_fn observer_clear;
static copy_fn observer_copy;
static publish_fn primary_publish, auxiliary_publish;
static local_copy_fn auxiliary_copy;

static void *load(const char *path) {
    int flags = RTLD_NOW | RTLD_GLOBAL;
#ifdef __APPLE__
    flags |= RTLD_FIRST; // The handle query must address just this image.
#endif
    void *handle = dlopen(path, flags);
    if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); exit(1); }
    return handle;
}
static void *required_symbol(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol) { fprintf(stderr, "missing %s: %s\n", name, dlerror()); exit(1); }
    return symbol;
}
static void verify_local_records(int64_t primary_value, int64_t auxiliary_value) {
    errno = EBUSY;
    observer_clear();
    assert(errno == EBUSY);
    jbclient_persona_diagnostic_v1 primary = {0}, auxiliary = {0};
    assert(observer_copy(&primary, sizeof(primary)) == 0 && errno == EBUSY);
    primary_publish(primary_value);
    assert(errno == EBUSY);
    auxiliary_publish(auxiliary_value);
    assert(errno == EBUSY);
    assert(observer_copy(&primary, sizeof(primary)) == 1 && errno == EBUSY);
    assert(auxiliary_copy(&auxiliary) == 1 && errno == EBUSY);
    assert(primary.version == 1 && primary.size == 56);
    assert(primary.original_result == primary_value && primary.result_valid);
    assert(auxiliary.original_result == auxiliary_value && auxiliary.result_valid);
    // Clearing the exported observer must leave the other image's TLS intact.
    observer_clear();
    assert(observer_copy(&primary, sizeof(primary)) == 0 && errno == EBUSY);
    assert(auxiliary_copy(&auxiliary) == 1 && auxiliary.original_result == auxiliary_value);
    assert(errno == EBUSY);
}
static void *thread_checks(void *context) {
    int64_t value = (int64_t)(uintptr_t)context;
    for (int i = 0; i < 100; i++) verify_local_records(value, -value);
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 4);
    bool auxiliary_first = !strcmp(argv[3], "auxiliary-first");
    void *primary, *auxiliary;
    if (auxiliary_first) {
        auxiliary = load(argv[2]);
        assert(!dlsym(RTLD_DEFAULT, "jbclient_persona_diagnostic_clear"));
        assert(!dlsym(RTLD_DEFAULT, "jbclient_persona_diagnostic_copy"));
        primary = load(argv[1]);
    } else { primary = load(argv[1]); auxiliary = load(argv[2]); }
    void *primary_clear = required_symbol(primary, "jbclient_persona_diagnostic_clear");
    void *primary_copy = required_symbol(primary, "jbclient_persona_diagnostic_copy");
    // The lookup used by Sileo must identify the wrapper's producer image,
    // independently of the loading order of unrelated embedded client copies.
    assert(dlsym(RTLD_DEFAULT, "jbclient_persona_diagnostic_clear") == primary_clear);
    assert(dlsym(RTLD_DEFAULT, "jbclient_persona_diagnostic_copy") == primary_copy);
    assert(!dlsym(auxiliary, "jbclient_persona_diagnostic_clear"));
    assert(!dlsym(auxiliary, "jbclient_persona_diagnostic_copy"));
    assert(!dlsym(primary, "jbclient_persona_diagnostic_publish"));
    assert(!dlsym(auxiliary, "jbclient_persona_diagnostic_publish"));
    // Dispatcher/handler observation still links across the launchdhook and
    // libjailbreak images; restricting the client getters must not hide it.
    (void)required_symbol(auxiliary, "jbserver_persona_diagnostic_begin");
    (void)required_symbol(auxiliary, "jbserver_persona_diagnostic_end");
    (void)required_symbol(auxiliary, "jbserver_persona_diagnostic_set_stage");
    observer_clear = (clear_fn)primary_clear;
    observer_copy = (copy_fn)primary_copy;
    primary_publish = (publish_fn)required_symbol(primary, "fixture_publish");
    auxiliary_publish = (publish_fn)required_symbol(auxiliary, "fixture_publish");
    auxiliary_copy = (local_copy_fn)required_symbol(auxiliary, "fixture_local_copy");
    verify_local_records(123, 456);
    primary_publish(91); auxiliary_publish(-91);
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, thread_checks, (void *)(i + 1)));
    for (int i = 0; i < 4; i++) assert(!pthread_join(threads[i], NULL));
    jbclient_persona_diagnostic_v1 record = {0};
    assert(observer_copy(&record, sizeof(record)) == 1 && record.original_result == 91);
    assert(auxiliary_copy(&record) == 1 && record.original_result == -91);
    printf("PASS %s: wrapper getters, local producers, same-thread errno and concurrent TLS isolation\n", argv[3]);
    // Keep handles loaded until process exit; thread-local records may still
    // be referenced by the host's runtime. This test removes no files.
    return 0;
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--sysroot")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform not in ("darwin", "linux"):
        raise SystemExit("This native dylib/shared-library test requires macOS or Linux")
    if not args.clang:
        raise SystemExit("clang is required")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    library_source = args.output_dir / "observation-library.c"
    loader_source = args.output_dir / "observation-loader.c"
    library_source.write_text(LIBRARY, encoding="utf-8")
    loader_source.write_text(LOADER, encoding="utf-8")
    extension = ".dylib" if sys.platform == "darwin" else ".so"
    primary = args.output_dir / ("wrapper-observation" + extension)
    auxiliary = args.output_dir / ("auxiliary-observation" + extension)
    binary = args.output_dir / "observation-loader"
    common = [args.clang, "-std=gnu11", "-g", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread", "-I", str(INCLUDE)]
    if args.sysroot:
        common += ["-isysroot", args.sysroot]
    library_flags = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
    for library, exports in ((primary, "1"), (auxiliary, "0")):
        subprocess.run(common + library_flags + ["-DJBCLIENT_PERSONA_DIAGNOSTIC_EXPORT_OBSERVER=" + exports,
            str(library_source), str(HELPER), "-o", str(library)], check=True, timeout=60)
    loader_flags = ["-ldl"] if sys.platform == "linux" else []
    subprocess.run(common + [str(loader_source)] + loader_flags + ["-o", str(binary)], check=True, timeout=60)
    for order in ("auxiliary-first", "wrapper-first"):
        subprocess.run([str(binary), str(primary), str(auxiliary), order], check=True, timeout=20)
    print("PASS two real modules use the correct passive observation; no identity operation executed")


if __name__ == "__main__":
    main()
