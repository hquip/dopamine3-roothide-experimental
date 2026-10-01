#ifndef ROOTHIDE_PROCESS_IDENTITY_H
#define ROOTHIDE_PROCESS_IDENTITY_H

#include <libproc.h>
#include <stdint.h>

// Keep this client helper independent of libjailbreak's kernel access code:
// systemhook compiles the XPC client sources without linking libjailbreak.
static inline uint64_t roothide_process_unique_id(pid_t pid)
{
    if (pid <= 0) return 0;
    struct {
        uint8_t uuid[16];
        uint64_t uniqueID;
        uint64_t parentUniqueID;
        int32_t pidVersion;
        uint32_t reserved2;
        uint64_t reserved3;
        uint64_t reserved4;
    } info = {0};
    // arg=1 includes unreaped zombies, preserving identity while cleanup waits
    // for the failed child to exit. arg=0 loses the identity at that transition.
    int length = proc_pidinfo(pid, 17 /* PROC_PIDUNIQIDENTIFIERINFO */, 1, &info, sizeof(info));
    return length == (int)sizeof(info) ? info.uniqueID : 0;
}

#endif
