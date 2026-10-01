#!/usr/bin/env python3
"""Test production dyld redirect encoding and VM failure handling on the host.

This does not execute an iOS loader or prove remote VM permissions on a device.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract_function(source: str, name: str) -> str:
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
#include <string.h>
#include "dyld_entry.h"
typedef int mach_port_t;
typedef int kern_return_t;
typedef uintptr_t vm_address_t;
typedef uintptr_t vm_offset_t;
typedef unsigned int mach_msg_type_number_t;
typedef void *thread_state_t;
typedef struct { void *pc; } arm_thread_state64_t;
#define ARM_THREAD_STATE64 6
#define __darwin_arm_thread_state64_set_pc_fptr(state, pointer) ((state).pc = (pointer))
#define KERN_SUCCESS 0
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_PROT_EXECUTE 4
#define VM_PROT_COPY 16
#define JBLogError(...) ((void)0)
struct mach_header_64 { uint32_t words[8]; };
static const uintptr_t headerAddress = 0x1000, entryAddress = 0x4ffc;
static const uint64_t destination = UINT64_C(0x000000019abcdef0);
static int callCount, failAt, stateCalls, unmapCalls, stateFailure, unmapFailure;
static unsigned char headerBytes[32];
static uint32_t entryWords[ROOTHIDE_DYLD_ENTRY_WORDS];
static int vm_protect(mach_port_t task, vm_address_t address, size_t length, bool maximum, int protection) {
    assert(task == 7 && !maximum);
    int stage = ++callCount;
    if (stage == 1 || stage == 3) {
        assert(address == entryAddress);
        // A redirect crossing a page boundary must restore the entire patch.
        assert(length == sizeof(entryWords));
    } else {
        assert(stage == 4 || stage == 6);
        assert(address == headerAddress && length == sizeof(headerBytes));
    }
    assert(protection == ((stage == 1 || stage == 4)
        ? VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY
        : VM_PROT_READ|VM_PROT_EXECUTE));
    return stage == failAt ? 5 : KERN_SUCCESS;
}
static int vm_write(mach_port_t task, vm_address_t address, vm_offset_t data, size_t length) {
    assert(task == 7);
    int stage = ++callCount;
    assert(stage == 2 || stage == 5);
    if (stage == failAt) return 5;
    if (stage == 2) {
        assert(address == entryAddress && length == sizeof(entryWords));
        memcpy(entryWords, (void *)data, length);
    } else {
        assert(address == headerAddress && length == sizeof(headerBytes));
        memcpy(headerBytes, (void *)data, length);
    }
    return KERN_SUCCESS;
}
@FUNCTION@
static void cs_allow_invalid(uint64_t proc, bool full) { assert(proc == 123 && !full); }
static int thread_set_state(mach_port_t thread, int flavor, thread_state_t state, unsigned count) {
    assert(thread == 8 && flavor == ARM_THREAD_STATE64 && count == 1);
    assert((uintptr_t)((arm_thread_state64_t *)state)->pc == destination);
    ++stateCalls;
    return stateFailure;
}
static int vm_deallocate(mach_port_t task, uintptr_t address, uint64_t size) {
    assert(task == 7 && address == headerAddress && size == 0x5000);
    ++unmapCalls;
    return unmapFailure;
}
@REDIRECT@
static void check_encoding(uint64_t address) {
    uint32_t code[ROOTHIDE_DYLD_ENTRY_WORDS];
    roothide_encode_dyld_entry(address, code);
    uint64_t registers[32];
    for (unsigned i = 0; i < 32; ++i) registers[i] = UINT64_C(0x12340000) + i;
    uint64_t original[32]; memcpy(original, registers, sizeof(original));
    for (unsigned i = 0; i < 4; ++i) {
        assert((code[i] & 31) == 17);
        assert((code[i] & 0xff800000) == (i == 0 ? 0xd2800000 : 0xf2800000));
        unsigned shift = ((code[i] >> 21) & 3) * 16;
        uint64_t immediate = (code[i] >> 5) & 0xffff;
        if (i == 0) registers[17] = immediate << shift;
        else registers[17] = (registers[17] & ~(UINT64_C(0xffff) << shift)) | (immediate << shift);
    }
    assert(code[4] == (0xd61f0000 | (17 << 5)));
    assert(registers[17] == address);
    for (unsigned i = 0; i < 32; ++i) if (i != 17) assert(registers[i] == original[i]);
}
int main(void) {
    assert(!roothide_dyld_entry_uses_trampoline(false, false));
    assert(roothide_dyld_entry_uses_trampoline(false, true));
    assert(roothide_dyld_entry_uses_trampoline(true, false));
    assert(roothide_dyld_entry_uses_trampoline(true, true));
    const uint64_t addresses[] = {0, 4, UINT64_C(0x123456789abcdef0), UINT64_MAX, destination};
    for (unsigned i = 0; i < sizeof(addresses)/sizeof(addresses[0]); ++i) check_encoding(addresses[i]);
    for (failAt = 0; failAt <= 6; ++failAt) {
        callCount = 0; memset(headerBytes, 0xa5, sizeof(headerBytes));
        memset(entryWords, 0, sizeof(entryWords));
        int result = hook_dyld_entry(7, headerAddress, entryAddress, destination);
        assert(result == (failAt ? -1 : 0));
        assert(callCount == (failAt ? failAt : 6));
        if (failAt >= 1 && failAt <= 5) for (unsigned i=0; i<sizeof(headerBytes); ++i) assert(headerBytes[i] == 0xa5);
        if (failAt == 0 || failAt == 6) for (unsigned i=0; i<sizeof(headerBytes); ++i) assert(headerBytes[i] == 0);
    }
    for (int modern = 0; modern <= 1; ++modern) for (int different = 0; different <= 1; ++different) {
        for (failAt = 0; failAt <= 6; ++failAt) {
            stateCalls = unmapCalls = callCount = 0;
            arm_thread_state64_t state = {0};
            int result = redirect_dyld_entry(7, 8, 123, headerAddress, entryAddress,
                (void *)(uintptr_t)destination, 0x5000, &state, 1, modern, different);
            if (modern || different) {
                assert(result == (failAt ? -1 : 0));
                // Including every VM failure: no retry via thread_set_state,
                // and never unmap the dyld holding the authenticated PC.
                assert(stateCalls == 0 && unmapCalls == 0);
            } else assert(result == 0 && stateCalls == 1 && unmapCalls == 1 && callCount == 0);
        }
    }
    arm_thread_state64_t state = {0};
    stateCalls = unmapCalls = callCount = 0;
    stateFailure = 5;
    assert(redirect_dyld_entry(7, 8, 123, headerAddress, entryAddress,
        (void *)(uintptr_t)destination, 0x5000, &state, 1, false, false) == -1);
    assert(stateCalls == 1 && unmapCalls == 0);
    stateFailure = 0; unmapFailure = 5;
    assert(redirect_dyld_entry(7, 8, 123, headerAddress, entryAddress,
        (void *)(uintptr_t)destination, 0x5000, &state, 1, false, false) == -1);
    puts("PASS production dyld policy, ARM64 jump semantics and all six VM failure stages");
    return 0;
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    args = parser.parse_args()
    if not args.clang:
        raise SystemExit("clang is required")
    source = (ROOT / "BaseBin/libjailbreak/src/roothider/dyld_patch.m").read_text(encoding="utf-8")
    # Bind the tested redirect to the production OS decision at its call site.
    caller = extract_function(source, "proc_patch_dyld_internal")
    assert "if (__builtin_available(iOS 17.0, *)) modernOS = true;" in caller
    assert "threadStateCount, modernOS, differentPACKey)" in caller
    assert "thread_set_state(" not in caller
    redirect = extract_function(source, "redirect_dyld_entry")
    with tempfile.TemporaryDirectory(prefix="roothide-dyld-entry-") as directory:
        cfile = Path(directory) / "test.c"
        binary = Path(directory) / ("test.exe" if os.name == "nt" else "test")
        cfile.write_text(HARNESS.replace("@FUNCTION@", extract_function(source, "hook_dyld_entry"))
                        .replace("@REDIRECT@", redirect), encoding="utf-8")
        subprocess.run([args.clang, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                        "-I", str(ROOT / "BaseBin/libjailbreak/src/roothider"),
                        str(cfile), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
