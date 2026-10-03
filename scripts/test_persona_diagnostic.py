#!/usr/bin/env python3
"""Test passive observations with production client/dispatcher and inert XPC.

No persona handler, entitlement lookup, process launch, identity helper, kernel,
or device is executed. The old client is compiled alongside the current client
to compare return values, errno, and object releases under the same fixtures.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CLIENT = "BaseBin/libjailbreak/src/jbclient_xpc.c"


def function(text: str, name: str) -> str:
    anchor = text.index(name + "(")
    start = text.rfind("\n", 0, anchor) + 1
    brace = text.index("{", anchor)
    # Comments and quoted strings can contain braces; use the schema tokenizer.
    _, end = schema_helpers()["balanced"](text, brace)
    return text[start:end] + "\n"


_helpers: dict | None = None


def schema_helpers() -> dict:
    global _helpers
    if _helpers is None:
        script = ROOT / "scripts/test_jbserver_schema.py"
        _helpers = {"__file__": str(script), "__name__": "fixture_helpers"}
        exec(compile(script.read_text(encoding="utf-8"), str(script), "exec"), _helpers)
    return _helpers


EXTRA_MOCK = r'''
#include "jb_persona_diagnostic_internal.h"
#include "jbserver_domains.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/types.h>
#include <pthread.h>
#endif
#define MACH_PORT_NULL 0
#define OS_ALLOC_ONCE_KEY_LIBXPC 0
static _Thread_local unsigned release_count;
static _Thread_local bool pipe_available;
static _Thread_local bool launchd_available;
static _Thread_local bool loopback;
static _Thread_local bool nested_transport;
static _Thread_local bool in_nested_transport;
static _Thread_local int transport_result;
static _Thread_local xpc_object_t transport_reply;
static _Thread_local uint64_t fixture_stage;
static _Thread_local bool nested_handler;
static _Thread_local bool in_nested_handler;
static _Thread_local uint64_t nested_observed_stage;
static _Thread_local mach_port_t gJBServerCustomPort;
@GLOBAL_DATA@
static _Thread_local struct xpc_global_data global_data;
static void *os_alloc_once(unsigned key, size_t size, void *initializer) {
    (void)key; (void)size; (void)initializer; return &global_data;
}
static mach_port_t jbclient_mach_get_launchd_port(void) { return launchd_available ? 1 : 0; }
static xpc_object_t xpc_pipe_create_from_port(mach_port_t port, unsigned flags) {
    (void)port; (void)flags; return pipe_available ? object(XPC_TYPE_DICTIONARY) : NULL;
}
static xpc_object_t xpc_retain(xpc_object_t value) { return value; }
static xpc_object_t xpc_dictionary_create_empty(void) { return object(XPC_TYPE_DICTIONARY); }
static int64_t xpc_int64_get_value(xpc_object_t value) { assert(value->type == XPC_TYPE_INT64); return (int64_t)value->number; }
static uint64_t xpc_uint64_get_value(xpc_object_t value) { assert(value->type == XPC_TYPE_UINT64); return value->number; }
static int xpc_pipe_routine_with_flags(xpc_object_t pipe, xpc_object_t request, xpc_object_t *reply, unsigned flags);
'''

TESTS = r'''
static bool persona_fixture_permission(audit_token_t token) {
    (void)token; permission_calls++; return !permission_denies;
}
static int persona_fixture_handler(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
    handler_calls++;
    jbserver_persona_diagnostic_set_stage(fixture_stage);
    if (nested_handler && !in_nested_handler) {
        in_nested_handler = true;
        uint64_t outer_stage = fixture_stage;
        fixture_stage = JB_PERSONA_DIAGNOSTIC_CHILD_PATH_FAILED;
        xpc_object_t inner = xpc_dictionary_create_empty();
        inner->expects_reply = true;
        xpc_dictionary_set_uint64(inner, "jb-domain", JBS_DOMAIN_SYSTEMWIDE);
        xpc_dictionary_set_uint64(inner, "action", JBS_SYSTEMWIDE_PERSONA_FIX);
        extern struct jbserver_impl fixture_server;
        assert(jbserver_received_xpc_message(&fixture_server, inner) == 0);
        nested_observed_stage = xpc_dictionary_get_uint64(last_reply, JB_PERSONA_DIAGNOSTIC_REPLY_KEY);
        fixture_stage = outer_stage;
        in_nested_handler = false;
    }
    errno = EDOM;
    return handler_result;
}
static struct jbserver_domain fixture_domain = {
    .permissionHandler = persona_fixture_permission,
    .actions = {
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[]){{0}}},
        {.handler = persona_fixture_handler, .args = (jbserver_arg[])@PERSONA_ARGS@},
        {0},
    },
};
struct jbserver_impl fixture_server = {
    .maxDomain = 1,
    .domains = (struct jbserver_domain *[]){&fixture_domain, NULL},
};
static int xpc_pipe_routine_with_flags(xpc_object_t pipe, xpc_object_t request, xpc_object_t *reply, unsigned flags) {
    (void)pipe; (void)flags;
    int result = transport_result;
    xpc_object_t scripted_reply = transport_reply;
    if (nested_transport && !in_nested_transport) {
        in_nested_transport = true;
        xpc_object_t unrelated = xpc_dictionary_create_empty();
        xpc_dictionary_set_uint64(unrelated, "jb-domain", JBS_DOMAIN_SYSTEMWIDE);
        xpc_dictionary_set_uint64(unrelated, "action", JBS_SYSTEMWIDE_GET_BOOT_UUID);
        assert(jbserver_xpc_send_dict(unrelated) == scripted_reply);
        in_nested_transport = false;
    }
    if (loopback) {
        request->expects_reply = true;
        assert(jbserver_received_xpc_message(&fixture_server, request) == 0);
        *reply = last_reply;
    } else *reply = scripted_reply;
    errno = EDOM;
    return result;
}
static void reset_fixture(void) {
    object_count = 0; last_reply = NULL;
    filter_calls = permission_calls = handler_calls = reply_calls = 0;
    filter_denies = permission_denies = false;
    release_count = 0;
    pipe_available = launchd_available = true;
    loopback = nested_transport = in_nested_transport = false;
    nested_handler = in_nested_handler = false;
    transport_result = 0; transport_reply = NULL;
    fixture_stage = JB_PERSONA_DIAGNOSTIC_UNKNOWN;
    handler_result = 0; nested_observed_stage = 0;
    gJBServerCustomPort = 1;
    global_data = (struct xpc_global_data){0};
    jbclient_persona_diagnostic_clear();
    errno = EBUSY;
}
static jbclient_persona_diagnostic_v1 snapshot(int expected) {
    jbclient_persona_diagnostic_v1 record;
    int saved_errno = errno;
    assert(jbclient_persona_diagnostic_copy(&record, sizeof(record)) == expected);
    assert(errno == saved_errno);
    assert(record.version == 1 && record.size == 56);
    return record;
}
static xpc_object_t reply_for(int mode) {
    if (mode == 0) return NULL;
    if (mode == 1) return object(XPC_TYPE_ARRAY);
    xpc_object_t reply = xpc_dictionary_create_empty();
    if (mode == 3) xpc_dictionary_set_string(reply, "result", "invalid");
    if (mode == 4) xpc_dictionary_set_int64(reply, "result", -1);
    if (mode == 5) xpc_dictionary_set_int64(reply, "result", EIO);
    if (mode == 6) xpc_dictionary_set_int64(reply, "result", 0);
    if (mode == 7) {
        xpc_dictionary_set_int64(reply, "result", 0x100000005LL);
        xpc_dictionary_set_uint64(reply, JB_PERSONA_DIAGNOSTIC_REPLY_KEY, 4);
    }
    if (mode == 8) {
        xpc_dictionary_set_int64(reply, "result", -1);
        xpc_dictionary_set_string(reply, JB_PERSONA_DIAGNOSTIC_REPLY_KEY, "invalid");
    }
    return reply;
}
struct outcome { int result; int saved_errno; unsigned releases; };
static struct outcome client_outcome(bool baseline, int mode, bool has_pipe, bool custom, int transport_error) {
    reset_fixture();
    pipe_available = has_pipe;
    launchd_available = has_pipe;
    gJBServerCustomPort = custom ? 1 : 0;
    transport_result = transport_error;
    transport_reply = reply_for(mode);
    int result = baseline ? baseline_jbclient_persona_fix(77, 0, 0) : jbclient_persona_fix(77, 0, 0);
    struct outcome out = {result, errno, release_count};
    if (!baseline) {
        jbclient_persona_diagnostic_v1 record = snapshot(1);
        assert(record.request_observed == 1);
        assert(record.pipe_available == has_pipe && record.ipc_called == has_pipe);
        if (has_pipe) {
            assert(record.ipc_result == transport_error);
            assert(record.reply_present == (!transport_error && mode != 0));
            assert(record.reply_dictionary == (!transport_error && mode >= 2));
            assert(record.result_valid == (!transport_error && mode >= 4));
            if (record.result_valid) {
                assert(record.original_result == xpc_int64_get_value(xpc_dictionary_get_value(transport_reply, "result")));
            }
            assert(record.server_stage_valid == (!transport_error && mode == 7));
            if (!transport_error && mode == 7) assert(record.server_stage == 4);
        } else assert(!record.reply_present && !record.result_valid && !record.server_stage_valid);
    }
    return out;
}
static void compare_original_client(void) {
    for (int mode = 0; mode <= 8; mode++) {
        for (int has_pipe = 0; has_pipe <= 1; has_pipe++) {
            for (int custom = 0; custom <= 1; custom++) {
                for (int transport_error = 0; transport_error <= 1; transport_error++) {
                    int error = transport_error ? EIO : 0;
                    struct outcome old = client_outcome(true, mode, has_pipe, custom, error);
                    struct outcome current = client_outcome(false, mode, has_pipe, custom, error);
                    assert(old.result == current.result);
                    assert(old.saved_errno == current.saved_errno);
                    assert(old.releases == current.releases);
                }
            }
        }
    }
    puts("PASS unchanged client result/errno/releases for 72 old/new fixtures");
}
static void api_and_nested_checks(void) {
    reset_fixture();
    (void)snapshot(0);
    jbclient_persona_diagnostic_v1 record = {.original_result = 123};
    assert(jbclient_persona_diagnostic_copy(NULL, 56) == -1 && errno == EBUSY);
    assert(jbclient_persona_diagnostic_copy(&record, 55) == -1 && errno == EBUSY);
    assert(record.original_result == 123);
    transport_result = EIO;
    transport_reply = (xpc_object_t)(uintptr_t)1; // Error-path pointer is not a valid XPC object.
    assert(jbclient_persona_fix(77, 0, 0) == -1);
    record = snapshot(1);
    assert(record.ipc_called && record.ipc_result == EIO);
    assert(!record.reply_present && !record.reply_dictionary && !record.result_valid);
    reset_fixture();
    assert(jbclient_persona_fix(0, 0, 0) == EINVAL);
    (void)snapshot(0);
    transport_reply = reply_for(5);
    nested_transport = true;
    assert(jbclient_persona_fix(77, 0, 0) == EIO);
    record = snapshot(1);
    assert(record.original_result == EIO && record.result_valid);
    xpc_object_t unrelated = xpc_dictionary_create_empty();
    xpc_dictionary_set_uint64(unrelated, "jb-domain", JBS_DOMAIN_SYSTEMWIDE);
    xpc_dictionary_set_uint64(unrelated, "action", JBS_SYSTEMWIDE_GET_BOOT_UUID);
    assert(jbserver_xpc_send_dict(unrelated) == transport_reply);
    jbclient_persona_diagnostic_v1 unchanged = snapshot(1);
    assert(memcmp(&record, &unchanged, sizeof(record)) == 0);
    errno = EBUSY;
    jbclient_persona_diagnostic_clear();
    assert(errno == EBUSY);
    record = snapshot(0);
    assert(!record.pipe_available && !record.ipc_called && !record.reply_present && !record.server_stage_valid);
    puts("PASS clear/getter errno, invalid buffer, invalid child, unrelated/nested IPC");
}
static void server_checks(void) {
    for (uint64_t stage = 0; stage <= 5; stage++) {
        for (int result = -1; result <= 1; result++) {
            reset_fixture(); loopback = true; fixture_stage = stage; handler_result = result;
            assert(jbclient_persona_fix(77, 0, 0) == result);
            jbclient_persona_diagnostic_v1 record = snapshot(1);
            assert(record.result_valid && record.original_result == result);
            assert(record.server_stage_valid && record.server_stage == stage);
            assert(handler_calls == 1 && reply_calls == 1);
        }
    }
    reset_fixture(); loopback = nested_handler = true;
    fixture_stage = JB_PERSONA_DIAGNOSTIC_EXISTING_HELPER_FAILED; handler_result = -1;
    assert(jbclient_persona_fix(77, 0, 0) == -1);
    assert(snapshot(1).server_stage == JB_PERSONA_DIAGNOSTIC_EXISTING_HELPER_FAILED);
    assert(nested_observed_stage == JB_PERSONA_DIAGNOSTIC_CHILD_PATH_FAILED);
    assert(handler_calls == 2 && reply_calls == 2);
    // Rejections before an existing handler keep their old result and never
    // manufacture a handler-stage observation.
    for (int mode = 0; mode < 4; mode++) {
        reset_fixture();
        xpc_object_t request = xpc_dictionary_create_empty();
        request->expects_reply = mode != 3;
        xpc_dictionary_set_uint64(request, "jb-domain", JBS_DOMAIN_SYSTEMWIDE);
        xpc_dictionary_set_uint64(request, "action", mode == 2 ? 9 : JBS_SYSTEMWIDE_PERSONA_FIX);
        filter_denies = mode == 0; permission_denies = mode == 1;
        int expected = mode < 2 ? EPERM : EINVAL;
        assert(jbserver_received_xpc_message_with_error_reply(&fixture_server, request) == expected);
        assert(handler_calls == 0);
        if (mode == 3) assert(reply_calls == 0);
        else {
            assert(reply_calls == 1 && last_reply);
            assert(xpc_dictionary_get_int64(last_reply, "result") == expected);
            assert(!xpc_dictionary_get_value(last_reply, JB_PERSONA_DIAGNOSTIC_REPLY_KEY));
        }
    }
    errno = EBUSY;
    jbserver_persona_diagnostic_set_stage(5); // Inactive scope must stay inactive.
    jbserver_persona_diagnostic_scope outer = jbserver_persona_diagnostic_begin();
    assert(jbserver_persona_diagnostic_end(outer) == 0 && errno == EBUSY);
    puts("PASS handler stages/results, scope reset/restoration, nested dispatcher, unchanged rejection replies");
}
#ifdef _WIN32
static DWORD WINAPI thread_check(void *context) {
#else
static void *thread_check(void *context) {
#endif
    uint64_t expected = (uint64_t)(uintptr_t)context;
    for (int i = 0; i < 50; i++) {
        reset_fixture(); loopback = true; fixture_stage = expected; handler_result = -(int)expected;
        assert(jbclient_persona_fix(77, 0, 0) == -(int)expected);
        jbclient_persona_diagnostic_v1 record = snapshot(1);
        assert(record.server_stage == expected && record.original_result == -(int)expected);
        errno = EBUSY; jbclient_persona_diagnostic_clear();
        assert(errno == EBUSY); (void)snapshot(0);
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}
static void thread_isolation(void) {
    reset_fixture(); loopback = true; fixture_stage = 5;
    assert(jbclient_persona_fix(77, 0, 0) == 0);
    jbclient_persona_diagnostic_v1 before = snapshot(1);
#ifdef _WIN32
    HANDLE threads[5];
    for (uintptr_t i = 0; i < 5; i++) { threads[i] = CreateThread(NULL, 0, thread_check, (void *)(i + 1), 0, NULL); assert(threads[i]); }
    assert(WaitForMultipleObjects(5, threads, TRUE, 10000) == WAIT_OBJECT_0);
    for (int i = 0; i < 5; i++) CloseHandle(threads[i]);
#else
    pthread_t threads[5];
    for (uintptr_t i = 0; i < 5; i++) assert(pthread_create(&threads[i], NULL, thread_check, (void *)(i + 1)) == 0);
    for (int i = 0; i < 5; i++) assert(pthread_join(threads[i], NULL) == 0);
#endif
    jbclient_persona_diagnostic_v1 after = snapshot(1);
    assert(memcmp(&before, &after, sizeof(before)) == 0);
    puts("PASS concurrent thread isolation and stale-record clearing");
}
int main(void) {
    compare_original_client(); api_and_nested_checks(); server_checks(); thread_isolation();
    puts("PASS passive observations only; no production identity operation executed");
    return 0;
}
'''


def fixture(baseline_ref: str) -> str:
    helpers = schema_helpers()
    mock = helpers["MOCK"].split("@DECLARATIONS@")[0]
    # Every fixture variable is thread-local; the concurrent test cannot race
    # its simulated transport or object pool and thereby mask observer races.
    mock = re.sub(r"^static (?=(?:struct fake_xpc objects|size_t object_count|xpc_object_t last_reply|int filter_calls|bool filter_denies))", "static _Thread_local ", mock, flags=re.M)
    mock = mock.replace("static void xpc_release(xpc_object_t value) { (void)value; }", "static void xpc_release(xpc_object_t value) { (void)value; release_count++; }")
    # release_count must precede its mock function.
    mock = mock.replace("struct field {", "static _Thread_local unsigned release_count;\nstruct field {")
    current = (ROOT / CLIENT).read_text(encoding="utf-8")
    baseline = subprocess.run(["git", "show", f"{baseline_ref}:{CLIENT}"], cwd=ROOT,
                              check=True, capture_output=True, text=True, timeout=15).stdout
    # Never execute the real identity handler. Instead require its source to be
    # identical to the baseline after removing only our five passive setters
    # and the two braces needed to annotate formerly single-line returns.
    handler_path = "BaseBin/launchdhook/src/jbserver/jbdomain_systemwide.c"
    old_handler_source = subprocess.run(
        ["git", "show", f"{baseline_ref}:{handler_path}"], cwd=ROOT, check=True,
        capture_output=True, text=True, timeout=15,
    ).stdout
    current_handler = function((ROOT / handler_path).read_text(encoding="utf-8"), "systemwide_persona_fix")
    expected_stages = ["ENTITLEMENT_DENIED", "CHILD_NOT_FOUND", "CHILD_PATH_FAILED", "EXISTING_HELPER_FAILED", "COMPLETED"]
    observed_stages = re.findall(r"jbserver_persona_diagnostic_set_stage\(JB_PERSONA_DIAGNOSTIC_(\w+)\);", current_handler)
    if observed_stages != expected_stages:
        raise ValueError("existing handler's five observation sites changed")
    original_logic = re.sub(r"^[ \t]*jbserver_persona_diagnostic_set_stage\([^\n]+\);\s*$", "", current_handler, flags=re.M)
    for condition in ("!hasPersonaMgmtEntitlement", "!childProc"):
        original_logic = re.sub(r"if\s*\(" + re.escape(condition) + r"\)\s*\{\s*return -1;\s*\}",
                                "if (" + condition + ") return -1;", original_logic)
    if re.sub(r"\s+", "", original_logic) != re.sub(r"\s+", "", function(old_handler_source, "systemwide_persona_fix")):
        raise ValueError("identity handler changed beyond passive observations")
    print("PASS five existing handler branches annotated; all original logic unchanged")
    names = ("jbserver_xpc_send_dict", "jbserver_xpc_send", "jbclient_persona_fix")
    client_code = "\n".join(function(current, name) for name in names)
    baseline_code = "\n".join(function(baseline, name) for name in names)
    for name in names:
        baseline_code = re.sub(r"\b" + name + r"\b", "baseline_" + name, baseline_code)
    global_data = re.search(r"struct xpc_global_data\s*\{.*?\};", current, re.S).group()
    extra = EXTRA_MOCK.replace("@GLOBAL_DATA@", global_data)
    extra = extra.replace("static _Thread_local unsigned release_count;\n", "")
    dispatcher = re.sub(r"^#include[^\n]*\n", "", helpers["source"](helpers["DISPATCHER"]), flags=re.M)
    persona_args = next(initializer for name, initializer in helpers["schemas"]() if name == "jbdomain_systemwide.c/systemwide_persona_fix/action-8")
    # Pure helper is linked as its actual C source, not duplicated in a fixture.
    return (mock + extra + helpers["declarations"]() + dispatcher + client_code
            + baseline_code + TESTS.replace("@PERSONA_ARGS@", persona_args))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--sysroot")
    parser.add_argument("--baseline-ref", default="HEAD")
    parser.add_argument("--generate-only", action="store_true",
                        help="Retain fixture for compiling on a different host")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if not args.clang:
        raise SystemExit("clang is required")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    source_file = args.output_dir / "persona-observation.c"
    binary = args.output_dir / ("persona-observation.exe" if os.name == "nt" else "persona-observation")
    source_file.write_text(fixture(args.baseline_ref), encoding="utf-8")
    if args.generate_only:
        print(source_file)
        return
    command = [args.clang, "-std=gnu11", "-g", "-O1", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-function", "-Wno-sign-compare", "-I", str(ROOT / "BaseBin/libjailbreak/src"),
               str(source_file), str(ROOT / "BaseBin/libjailbreak/src/jbclient_persona_diagnostic.c"),
               "-o", str(binary)]
    if args.sysroot:
        command += ["-isysroot", args.sysroot]
    if os.name != "nt":
        command += ["-pthread", "-fsanitize=address", "-fno-omit-frame-pointer"]
    subprocess.run(command, check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    main()
