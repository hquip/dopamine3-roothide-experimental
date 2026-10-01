#ifndef ROOTHIDE_DYLD_ENTRY_H
#define ROOTHIDE_DYLD_ENTRY_H

#include <stdbool.h>
#include <stdint.h>

// Hardened iOS 17+ targets can make thread_set_state fatal to its caller.
// Preserve the kernel-authenticated PC and redirect execution in the image.
static inline bool roothide_dyld_entry_uses_trampoline(bool modernOS, bool differentPACKey)
{
    return modernOS || differentPACKey;
}

#define ROOTHIDE_DYLD_ENTRY_WORDS 5
static inline void roothide_encode_dyld_entry(uint64_t target,
    uint32_t codes[ROOTHIDE_DYLD_ENTRY_WORDS])
{
    // x17 is an inter-procedure scratch register; preserve arguments and SP.
    codes[0] = 0xD2E00011 | (((target >> 48) & 0xffff) << 5); // movz x17, ..., lsl 48
    codes[1] = 0xF2C00011 | (((target >> 32) & 0xffff) << 5); // movk x17, ..., lsl 32
    codes[2] = 0xF2A00011 | (((target >> 16) & 0xffff) << 5); // movk x17, ..., lsl 16
    codes[3] = 0xF2800011 | (((target >>  0) & 0xffff) << 5); // movk x17, ...
    codes[4] = 0xD61F0220; // br x17 (not an authenticated cross-process pointer)
}

#endif
