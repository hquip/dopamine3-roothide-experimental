#!/usr/bin/env python3
"""ASan-check production RPC schemas with the real dispatcher and inert XPC fixtures.

No production handler, entitlement API, process launch, device, or kernel operation
is linked. Both descriptors and dispatcher source are extracted from the worktree.
--baseline-ref HEAD additionally requires the three old schemas and the old
eight-slot loop to produce an AddressSanitizer out-of-bounds report.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILES = sorted(
    (ROOT / "BaseBin/launchdhook/src/jbserver").glob("jbdomain_*.c")
) + [ROOT / "BaseBin/libjailbreak/src/jbserver_boomerang.c"]
DISPATCHER = "BaseBin/libjailbreak/src/jbserver.c"
HEADER = "BaseBin/libjailbreak/src/jbserver.h"


def source(path: str | Path, ref: str | None = None) -> str:
    relative = Path(path).relative_to(ROOT).as_posix() if Path(path).is_absolute() else str(path)
    if ref is not None:
        return subprocess.run(
            ["git", "show", f"{ref}:{relative}"], cwd=ROOT, check=True,
            capture_output=True, text=True, timeout=15,
        ).stdout
    return (ROOT / relative).read_text(encoding="utf-8")


def balanced(text: str, start: int) -> tuple[str, int]:
    """Return a C brace initializer, ignoring braces inside comments/strings."""
    depth = 0
    token = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'([^\'\\]|\\.)*\'|[{}]', re.S)
    for match in token.finditer(text, start):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return text[start:match.end()], match.end()
    raise ValueError("unterminated C initializer")


def schemas(ref: str | None = None) -> list[tuple[str, str]]:
    result = []
    for path in SCHEMA_FILES:
        text = source(path, ref)
        for ordinal, match in enumerate(re.finditer(r'\.args\s*=\s*\(jbserver_arg\[\]\)\s*\{', text), 1):
            initializer, _ = balanced(text, match.end() - 1)
            handler = re.findall(r'\.handler\s*=\s*(\w+)', text[:match.start()])[-1]
            result.append((f"{path.name}/{handler}/action-{ordinal}", initializer))
    if len(result) != 37:
        raise ValueError(f"expected all 37 production schemas, got {len(result)}")
    return result


def declarations() -> str:
    text = source(HEADER)
    patterns = [
        r'typedef enum\s*\{.*?\}\s*jbserver_type;',
        r'typedef struct s_jbserver_arg\s*\{.*?\}\s*jbserver_arg;',
        r'struct jbserver_action\s*\{.*?\};',
        r'struct jbserver_domain\s*\{.*?\};',
        r'struct jbserver_impl\s*\{.*?\};',
    ]
    return "\n".join(re.search(pattern, text, re.S).group() for pattern in patterns)


MOCK = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

typedef struct { uint32_t value[8]; } audit_token_t;
typedef uint32_t mach_port_t;
enum { XPC_TYPE_DICTIONARY = 1, XPC_TYPE_BOOL, XPC_TYPE_UINT64,
       XPC_TYPE_INT64, XPC_TYPE_STRING, XPC_TYPE_DATA, XPC_TYPE_ARRAY };
typedef struct fake_xpc *xpc_object_t;
struct field { const char *key; xpc_object_t value; };
struct fake_xpc {
    int type; uint64_t number; const char *string;
    const void *data; size_t length; bool expects_reply;
    size_t count; struct field fields[32];
};
static struct fake_xpc objects[256];
static size_t object_count;
static xpc_object_t last_reply;
static int filter_calls, permission_calls, handler_calls, reply_calls, handler_result;
static bool filter_denies, permission_denies;
static xpc_object_t object(int type) {
    assert(object_count < sizeof(objects) / sizeof(objects[0]));
    xpc_object_t result = &objects[object_count++];
    memset(result, 0, sizeof(*result)); result->type = type; return result;
}
static int xpc_get_type(xpc_object_t value) { return value ? value->type : 0; }
static xpc_object_t xpc_dictionary_get_value(xpc_object_t dictionary, const char *key) {
    assert(dictionary && dictionary->type == XPC_TYPE_DICTIONARY);
    for (size_t i = 0; i < dictionary->count; i++)
        if (!strcmp(dictionary->fields[i].key, key)) return dictionary->fields[i].value;
    return NULL;
}
static void xpc_dictionary_set_value(xpc_object_t dictionary, const char *key, xpc_object_t value) {
    assert(dictionary && dictionary->type == XPC_TYPE_DICTIONARY);
    for (size_t i = 0; i < dictionary->count; i++) {
        if (!strcmp(dictionary->fields[i].key, key)) { dictionary->fields[i].value = value; return; }
    }
    assert(dictionary->count < 32);
    dictionary->fields[dictionary->count++] = (struct field){key, value};
}
static void set_number(xpc_object_t dictionary, const char *key, int type, uint64_t number) {
    xpc_object_t value = object(type); value->number = number;
    xpc_dictionary_set_value(dictionary, key, value);
}
static uint64_t get_number(xpc_object_t dictionary, const char *key, int type) {
    xpc_object_t value = xpc_dictionary_get_value(dictionary, key);
    return value && value->type == type ? value->number : 0;
}
static void xpc_dictionary_set_uint64(xpc_object_t d, const char *k, uint64_t v) { set_number(d,k,XPC_TYPE_UINT64,v); }
static void xpc_dictionary_set_int64(xpc_object_t d, const char *k, int64_t v) { set_number(d,k,XPC_TYPE_INT64,(uint64_t)v); }
static void xpc_dictionary_set_bool(xpc_object_t d, const char *k, bool v) { set_number(d,k,XPC_TYPE_BOOL,v); }
static uint64_t xpc_dictionary_get_uint64(xpc_object_t d, const char *k) { return get_number(d,k,XPC_TYPE_UINT64); }
static int64_t xpc_dictionary_get_int64(xpc_object_t d, const char *k) { return (int64_t)get_number(d,k,XPC_TYPE_INT64); }
static bool xpc_dictionary_get_bool(xpc_object_t d, const char *k) { return get_number(d,k,XPC_TYPE_BOOL) != 0; }
static void xpc_dictionary_set_string(xpc_object_t d, const char *k, const char *s) {
    xpc_object_t value = object(XPC_TYPE_STRING); value->string = s; xpc_dictionary_set_value(d,k,value);
}
static const char *xpc_dictionary_get_string(xpc_object_t d, const char *k) {
    xpc_object_t value = xpc_dictionary_get_value(d,k);
    return value && value->type == XPC_TYPE_STRING ? value->string : NULL;
}
static void xpc_dictionary_set_data(xpc_object_t d, const char *k, const void *p, size_t length) {
    xpc_object_t value = object(XPC_TYPE_DATA); value->data = p; value->length = length;
    xpc_dictionary_set_value(d,k,value);
}
static const void *xpc_dictionary_get_data(xpc_object_t d, const char *k, size_t *length) {
    xpc_object_t value = xpc_dictionary_get_value(d,k);
    *length = value && value->type == XPC_TYPE_DATA ? value->length : 0;
    return value && value->type == XPC_TYPE_DATA ? value->data : NULL;
}
static xpc_object_t get_object(xpc_object_t d, const char *k, int type) {
    xpc_object_t value = xpc_dictionary_get_value(d,k); return value && value->type == type ? value : NULL;
}
static xpc_object_t xpc_dictionary_get_array(xpc_object_t d, const char *k) { return get_object(d,k,XPC_TYPE_ARRAY); }
static xpc_object_t xpc_dictionary_get_dictionary(xpc_object_t d, const char *k) { return get_object(d,k,XPC_TYPE_DICTIONARY); }
/* No real file descriptor or Mach right is created or used by these fixtures. */
static int xpc_dictionary_dup_fd(xpc_object_t d, const char *k) { (void)d; (void)k; return -1; }
static int xpc_dictionary_extract_mach_recv(xpc_object_t d, const char *k) { (void)d; (void)k; return 0; }
static int xpc_dictionary_copy_mach_send(xpc_object_t d, const char *k) { (void)d; (void)k; return 0; }
static void xpc_dictionary_set_fd(xpc_object_t d, const char *k, int v) { xpc_dictionary_set_int64(d,k,v); }
static void xpc_dictionary_set_mach_recv(xpc_object_t d, const char *k, int v) { xpc_dictionary_set_int64(d,k,v); }
static void xpc_dictionary_set_mach_send(xpc_object_t d, const char *k, int v) { xpc_dictionary_set_int64(d,k,v); }
static void xpc_dictionary_get_audit_token(xpc_object_t d, audit_token_t *token) { (void)d; token->value[0] = 123; }
static xpc_object_t xpc_dictionary_create_reply(xpc_object_t d) { return d->expects_reply ? object(XPC_TYPE_DICTIONARY) : NULL; }
static int xpc_pipe_routine_reply(xpc_object_t d) { last_reply = d; reply_calls++; return 0; }
static void xpc_release(xpc_object_t value) { (void)value; }
static int close(int fd) { assert(fd == -1); return 0; }
static bool roothide_handle_xpc_msg(xpc_object_t value) { (void)value; filter_calls++; return filter_denies; }
@DECLARATIONS@
@DISPATCHER@

struct schema { const char *name; const jbserver_arg *args; size_t count; };
@SCHEMAS@
static bool fixture_permission(audit_token_t token) {
    assert(token.value[0] == 123); permission_calls++; return !permission_denies;
}
static int fixture_handler(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
    handler_calls++; return handler_result;
}
static void reset(void) {
    object_count = 0; last_reply = NULL;
    filter_calls = permission_calls = handler_calls = reply_calls = 0;
    handler_result = 0;
    filter_denies = permission_denies = false;
}
static xpc_object_t request(void) {
    xpc_object_t d = object(XPC_TYPE_DICTIONARY); d->expects_reply = true;
    xpc_dictionary_set_uint64(d, "jb-domain", 1); xpc_dictionary_set_uint64(d, "action", 1);
    return d;
}
static struct jbserver_domain *domain_for(jbserver_arg *args) {
    struct jbserver_domain *domain = calloc(1, sizeof(*domain) + 2 * sizeof(struct jbserver_action));
    assert(domain); domain->permissionHandler = fixture_permission;
    domain->actions[0].handler = fixture_handler; domain->actions[0].args = args; return domain;
}
static void check_schema(const struct schema *schema) {
    reset();
    /* Exact-sized heap copies ensure ASan detects missing or skipped sentinels. */
    jbserver_arg *args = malloc(schema->count * sizeof(*args)); assert(args);
    memcpy(args, schema->args, schema->count * sizeof(*args));
    struct jbserver_domain *domain = domain_for(args);
    struct jbserver_domain *domains[] = {domain, NULL};
    struct jbserver_impl server = {.maxDomain = 1, .domains = domains};
    xpc_object_t d = request();
    for (size_t i = 0; i < schema->count; i++) {
        if (args[i].name && !args[i].out && args[i].type == JBS_TYPE_DATA)
            xpc_dictionary_set_data(d, args[i].name, "fixture", 7);
    }
    int result = jbserver_received_xpc_message_with_error_reply(&server, d);
    assert(result == 0 && handler_calls == 1 && permission_calls == 1 && filter_calls == 1 && reply_calls == 1);
    assert(last_reply && xpc_get_type(xpc_dictionary_get_value(last_reply,"result")) == XPC_TYPE_INT64);
    assert(xpc_dictionary_get_int64(last_reply,"result") == 0);
    free(domain); free(args); printf("PASS schema: %s\n", schema->name);
}
static void eight_slots(void) {
    /* Deliberately no ninth descriptor: bound must be checked before name. */
    const jbserver_arg args[8] = {
        {.name="a"}, {.name="b"}, {.name="c"}, {.name="d"},
        {.name="e"}, {.name="f"}, {.name="g"}, {.name="h"},
    };
    const struct schema schema = {"eight slots without ninth descriptor",args,8}; check_schema(&schema);
}
static void rejection_checks(void) {
    jbserver_arg args[] = {{.name="nonce",.type=JBS_TYPE_UINT64},{0}};
    struct jbserver_domain *domain = domain_for(args);
    struct jbserver_domain *domains[] = {domain,NULL};
    struct jbserver_impl server = {.maxDomain=1,.domains=domains};
    for (int mode=0; mode<10; mode++) {
        reset(); xpc_object_t d=request(); int expected=EINVAL;
        if (mode==0) { permission_denies=true; expected=EPERM; }
        if (mode==1) { filter_denies=true; expected=EPERM; }
        if (mode==2) xpc_dictionary_set_uint64(d,"action",2);
        if (mode==3) xpc_dictionary_set_string(d,"action","1");
        if (mode==4) xpc_dictionary_set_value(d,"action",NULL);
        if (mode==5) d->expects_reply=false;
        if (mode==6) d=object(XPC_TYPE_ARRAY);
        if (mode==7) xpc_dictionary_set_uint64(d,"jb-domain",2);
        if (mode==8) xpc_dictionary_set_string(d,"jb-domain","1");
        if (mode==9) xpc_dictionary_set_value(d,"jb-domain",NULL);
        assert(jbserver_received_xpc_message_with_error_reply(&server,d)==expected);
        assert(handler_calls==0);
        if (mode!=5 && mode!=6) {
            assert(reply_calls==1 && last_reply);
            assert(xpc_get_type(xpc_dictionary_get_value(last_reply,"result"))==XPC_TYPE_INT64);
            assert(xpc_dictionary_get_int64(last_reply,"result")==expected);
        } else assert(reply_calls==0);
    }
    const int failures[] = {-1,EIO,EPERM,EINVAL};
    for (size_t i=0; i<sizeof(failures)/sizeof(failures[0]); i++) {
        reset(); handler_result=failures[i]; xpc_object_t d=request();
        assert(jbserver_received_xpc_message_with_error_reply(&server,d)==0);
        assert(handler_calls==1 && reply_calls==1 && last_reply);
        assert(xpc_get_type(xpc_dictionary_get_value(last_reply,"result"))==XPC_TYPE_INT64);
        assert(xpc_dictionary_get_int64(last_reply,"result")==handler_result);
    }
    free(domain); puts("PASS rejection/result fixtures (real dispatcher; simulated XPC)");
}
int main(int argc, char **argv) {
    if (argc==2 && !strcmp(argv[1],"eight")) { eight_slots(); return 0; }
    if (argc==2) {
        for (size_t i=0; i<sizeof(schemas)/sizeof(schemas[0]); i++)
            if (!strcmp(argv[1],schemas[i].name)) { check_schema(&schemas[i]); return 0; }
        return 2;
    }
    for (size_t i=0; i<sizeof(schemas)/sizeof(schemas[0]); i++) check_schema(&schemas[i]);
    eight_slots(); rejection_checks();
    puts("PASS all actual-schema memory checks; no device/root-identity compatibility claim");
    return 0;
}
'''


def fixture(ref: str | None = None) -> str:
    arrays = []
    entries = []
    for i, (name, initializer) in enumerate(schemas(ref)):
        arrays.append(f"static const jbserver_arg schema_{i}[] = {initializer};")
        entries.append(f'{{"{name}", schema_{i}, sizeof(schema_{i})/sizeof(schema_{i}[0])}}')
    arrays.append("static const struct schema schemas[] = {" + ",\n".join(entries) + "};")
    dispatcher = re.sub(r'^#include[^\n]*\n', '', source(DISPATCHER, ref), flags=re.M)
    return (MOCK.replace("@DECLARATIONS@", declarations())
            .replace("@DISPATCHER@", dispatcher).replace("@SCHEMAS@", "\n".join(arrays)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--sysroot", help="Explicit host SDK for native macOS tests")
    parser.add_argument("--baseline-ref", help="Git ref with old arrays/loop for negative ASan checks")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="Retained native test artifacts; this script deletes no files")
    args = parser.parse_args()
    if not args.clang:
        raise SystemExit("clang with AddressSanitizer is required")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"

    def build(name: str, ref: str | None = None) -> Path:
        cfile = args.output_dir / f"{name}.c"
        binary = args.output_dir / (name + (".exe" if os.name == "nt" else ""))
        cfile.write_text(fixture(ref), encoding="utf-8")
        command = [args.clang,"-std=gnu11","-g","-O1","-fsanitize=address",
                   "-fno-omit-frame-pointer",str(cfile),"-o",str(binary)]
        if args.sysroot:
            command += ["-isysroot", args.sysroot]
        subprocess.run(command, check=True, timeout=60)
        return binary

    current = build("jbserver-schema-current")
    subprocess.run([str(current)], check=True, env=environment, timeout=20)
    if args.baseline_ref:
        baseline = build("jbserver-schema-baseline", args.baseline_ref)
        probes = ["jbdomain_systemwide.c/jbsettings_get/action-7",
                  "jbdomain_systemwide.c/systemwide_persona_fix/action-8",
                  "jbdomain_root.c/roothide_unsupport_request/action-7", "eight"]
        for i, probe in enumerate(probes):
            result = subprocess.run([str(baseline),probe], env=environment,
                                    capture_output=True, text=True, timeout=20)
            report = result.stdout + result.stderr
            (args.output_dir/f"baseline-{i}.txt").write_text(report,encoding="utf-8")
            if result.returncode==0 or "AddressSanitizer" not in report or "buffer-overflow" not in report:
                raise SystemExit(f"baseline did not reproduce an ASan bounds failure: {probe}")
            print(f"PASS expected old-schema ASan failure: {probe}")


if __name__ == "__main__":
    main()
