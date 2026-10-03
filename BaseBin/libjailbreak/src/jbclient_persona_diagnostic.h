#ifndef JBCLIENT_PERSONA_DIAGNOSTIC_H
#define JBCLIENT_PERSONA_DIAGNOSTIC_H

#include <stddef.h>
#include <stdint.h>

#define JBCLIENT_PERSONA_DIAGNOSTIC_VERSION 1u
#define JBCLIENT_PERSONA_DIAGNOSTIC_SIZE 56u

/* Optional observation of existing action 8; these values do not affect it. */
enum jb_persona_diagnostic_stage {
	JB_PERSONA_DIAGNOSTIC_UNKNOWN = 0,
	JB_PERSONA_DIAGNOSTIC_ENTITLEMENT_DENIED = 1,
	JB_PERSONA_DIAGNOSTIC_CHILD_NOT_FOUND = 2,
	JB_PERSONA_DIAGNOSTIC_CHILD_PATH_FAILED = 3,
	JB_PERSONA_DIAGNOSTIC_EXISTING_HELPER_FAILED = 4,
	JB_PERSONA_DIAGNOSTIC_COMPLETED = 5,
};

/* All flag fields are 0 or 1. original_result is the unmodified wire INT64.
 * ipc_result is valid only when ipc_called. Reply flags are only observed when
 * ipc_called && ipc_result == 0; result fields also have their own validity
 * flags. No process identifier, credential, or path is stored.
 */
typedef struct jbclient_persona_diagnostic_v1 {
	uint32_t version;
	uint32_t size;
	uint32_t request_observed;
	uint32_t pipe_available;
	uint32_t ipc_called;
	int32_t ipc_result;
	uint32_t reply_present;
	uint32_t reply_dictionary;
	uint32_t result_valid;
	uint32_t server_stage_valid;
	int64_t original_result;
	uint64_t server_stage;
} jbclient_persona_diagnostic_v1;

#ifdef __cplusplus
extern "C" {
#endif

/* Same-thread observation only. Both functions preserve errno and do no IPC.
 * copy: 1 = observed request, 0 = no request since clear, -1 = invalid buffer.
 * A caller can discover these optional functions with dlsym on older libraries.
 */
void jbclient_persona_diagnostic_clear(void);
int jbclient_persona_diagnostic_copy(jbclient_persona_diagnostic_v1 *out, uint32_t out_size);

#ifdef __cplusplus
}
static_assert(sizeof(jbclient_persona_diagnostic_v1) == JBCLIENT_PERSONA_DIAGNOSTIC_SIZE, "diagnostic ABI size");
static_assert(offsetof(jbclient_persona_diagnostic_v1, original_result) == 40, "diagnostic result offset");
static_assert(offsetof(jbclient_persona_diagnostic_v1, server_stage) == 48, "diagnostic stage offset");
#else
_Static_assert(sizeof(jbclient_persona_diagnostic_v1) == JBCLIENT_PERSONA_DIAGNOSTIC_SIZE, "diagnostic ABI size");
_Static_assert(offsetof(jbclient_persona_diagnostic_v1, original_result) == 40, "diagnostic result offset");
_Static_assert(offsetof(jbclient_persona_diagnostic_v1, server_stage) == 48, "diagnostic stage offset");
#endif

#endif
