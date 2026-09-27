/*
 * RootHide 2 / Dopamine 3 protocol migration regression checks.
 *
 * The legacy constants below describe the LP64 iOS ABI of RootHide tag 27:
 * https://github.com/roothide/Dopamine2-roothide/blob/3824f2731275423c970ff6ed6685957dec269073/BaseBin/libjailbreak/src/jbserver.h
 * The golden values were independently checked with the unchanged tag-27
 * jbserver.h/signatures.h, its pinned ChOma headers (b1a4f2de), and the real
 * iPhoneOS 16.5 SDK for arm64 and arm64e. They are not derived from the current
 * port's declarations. Only project headers and the SDK supply the types.
 *
 * From the repository root on macOS, after BaseBin/.include is populated:
 *
 * xcrun --sdk iphoneos clang -arch arm64 -std=gnu11 -fblocks \
 *   -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
 *   -miphoneos-version-min=15.0 -IBaseBin/libjailbreak/src \
 *   -IBaseBin/.include -fsyntax-only -Werror tests/protocol_abi.c
 *
 * Repeat the same command with -arch arm64e. No linking or device access is
 * needed; a compile failure indicates an ABI/signature regression or a real
 * SDK/header incompatibility. A pass does not validate runtime behavior.
 */

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/syslimits.h>
#include <fcntl.h>
#include <mach/mach.h>

#include "jbclient_mach.h"
#include "jbclient_xpc.h"

#if !defined(__APPLE__) || !defined(__LP64__) || \
    !(defined(__arm64__) || defined(__aarch64__))
#error "Compile this test for the arm64 or arm64e Apple iOS ABI."
#endif
#if !TARGET_OS_IOS || TARGET_OS_SIMULATOR
#error "Use the iPhoneOS device SDK, not a host or simulator SDK."
#endif

#define ABI_SIZE(type, expected) \
    _Static_assert(sizeof(type) == (expected), #type " size changed")
#define ABI_OFFSET(type, member, expected) \
    _Static_assert(offsetof(type, member) == (expected), #type "." #member " offset changed")

/* SDK primitives participate in the wire ABI; do not replace them with stubs. */
ABI_SIZE(void *, 8);
ABI_SIZE(bool, 1);
ABI_SIZE(pid_t, 4);
ABI_SIZE(mach_msg_header_t, 24);
ABI_SIZE(fsignatures_t, 56);
_Static_assert(PATH_MAX == 1024, "Changing PATH_MAX changes check-in replies");
ABI_OFFSET(fsignatures_t, fs_file_start, 0);
ABI_OFFSET(fsignatures_t, fs_blob_start, 8);
ABI_OFFSET(fsignatures_t, fs_blob_size, 16);
/* SDK sys/fcntl.h includes these F_ADDFILESIGS_INFO fields in fsignatures_t. */
ABI_OFFSET(fsignatures_t, fs_fsignatures_size, 24);
ABI_OFFSET(fsignatures_t, fs_cdhash, 32);
ABI_OFFSET(fsignatures_t, fs_hash_type, 52);

/* Fields shared with the original tag-27 protocol. */
ABI_SIZE(struct jbserver_mach_msg, 40);
ABI_OFFSET(struct jbserver_mach_msg, hdr, 0);
ABI_OFFSET(struct jbserver_mach_msg, magic, 24);
ABI_OFFSET(struct jbserver_mach_msg, action, 32);
ABI_SIZE(struct jbserver_mach_msg_reply, 48);
ABI_OFFSET(struct jbserver_mach_msg_reply, msg, 0);
ABI_OFFSET(struct jbserver_mach_msg_reply, status, 40);
ABI_SIZE(struct jbserver_mach_msg_checkin, 40);
ABI_OFFSET(struct jbserver_mach_msg_checkin, base, 0);
ABI_SIZE(struct jbserver_mach_msg_forkfix, 48);
ABI_OFFSET(struct jbserver_mach_msg_forkfix, childPid, 40);
ABI_SIZE(struct jbserver_mach_msg_forkfix_reply, 48);
ABI_SIZE(struct jbserver_mach_msg_trust_fd_reply, 48);

ABI_SIZE(signature_source_t, 4);
_Static_assert(SIGNATURE_SOURCE_FILE == 0, "Legacy FILE wire value changed");
_Static_assert(SIGNATURE_SOURCE_PROC == 1, "Legacy PROC wire value changed");
_Static_assert(SIGNATURE_SOURCE_ALLOCATION == 2, "V3 ALLOCATION wire value changed");
ABI_SIZE(struct siginfo, 64);
ABI_OFFSET(struct siginfo, source, 0);
ABI_OFFSET(struct siginfo, signature, 8);

/* Original tag-27 replies: preserve every payload field, not only sizeof. */
ABI_SIZE(struct jbserver_mach_msg_checkin_reply_legacy, 3112);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply_legacy, base, 0);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply_legacy, fullyDebugged, 48);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply_legacy, jbRootPath, 49);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply_legacy, bootUUID, 1073);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply_legacy, sandboxExtensions, 1110);
ABI_SIZE(struct jbserver_mach_msg_trust_fd_legacy, 120);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd_legacy, base, 0);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd_legacy, fd, 40);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd_legacy, siginfoPopulated, 48);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd_legacy, siginfo, 56);

/* V3 check-in changes field positions even though the total size stays equal. */
ABI_SIZE(struct jbserver_mach_msg_checkin_reply, 3112);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply, fullyDebugged, 48);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply, forceCSAdhoc, 49);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply, jbRootPath, 50);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply, bootUUID, 1074);
ABI_OFFSET(struct jbserver_mach_msg_checkin_reply, sandboxExtensions, 1111);
ABI_SIZE(struct jbserver_mach_msg_trust_fd, 128);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd, fd, 40);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd, siginfoPopulated, 48);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd, siginfo, 56);
ABI_OFFSET(struct jbserver_mach_msg_trust_fd, attach, 120);

_Static_assert(JBSERVER_MACH_MAGIC_LEGACY == UINT64_C(0x444F50414D494E45),
               "Legacy requests must retain their original protocol magic");
_Static_assert(JBSERVER_MACH_MAGIC_V3 == UINT64_C(0x444F50414D494E33),
               "Versioned requests must retain their V3 protocol magic");
_Static_assert(JBSERVER_MACH_MAGIC_LEGACY != JBSERVER_MACH_MAGIC_V3,
               "Same-size check-in requests need distinct version markers");

/*
 * Assigning each real declaration to a typed function pointer is deliberately
 * stricter than counting arguments in source text. With -Werror, changed
 * pointer depth, return type, parameter type or arity fails compilation.
 */
void protocol_abi_check_function_signatures(void);
void protocol_abi_check_function_signatures(void)
{
    int (*legacy_xpc_checkin)(char **, char **, char **, bool *) = jbclient_process_checkin;
    int (*v3_xpc_checkin)(char **, char **, char **, bool *, bool *) = jbclient_process_checkin_v3;
    int (*legacy_xpc_trust)(int, struct siginfo *) = jbclient_trust_file;
    int (*v3_xpc_trust)(int, struct siginfo *, bool) = jbclient_trust_file_v3;
    int (*legacy_mach_checkin)(char *, char *, char *, bool *) = jbclient_mach_process_checkin;
    int (*v3_mach_checkin)(char *, char *, char *, bool *, bool *) = jbclient_mach_process_checkin_v3;
    int (*legacy_mach_trust)(int, struct siginfo *) = jbclient_mach_trust_file;
    int (*v3_mach_trust)(int, struct siginfo *, bool) = jbclient_mach_trust_file_v3;

    (void)legacy_xpc_checkin;
    (void)v3_xpc_checkin;
    (void)legacy_xpc_trust;
    (void)v3_xpc_trust;
    (void)legacy_mach_checkin;
    (void)v3_mach_checkin;
    (void)legacy_mach_trust;
    (void)v3_mach_trust;
}
