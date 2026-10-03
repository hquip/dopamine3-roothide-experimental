/* Mock data only: no spawn, IPC, device access, persona or privilege operation. */
#include "../Sileo/Backend/C Contrib/jbclient_persona_diagnostic.h"
#include <errno.h>
#include <limits.h>
#include <string.h>

_Static_assert(_Alignof(jbclient_persona_diagnostic_v1) == 8, "diagnostic alignment");
static _Thread_local jbclient_persona_diagnostic_v1 observation;
static _Thread_local int copy_result;

#ifndef OMIT_CLEAR
void jbclient_persona_diagnostic_clear(void)
{
    int saved_errno = errno;
    memset(&observation, 0, sizeof(observation));
    observation.version = JBCLIENT_PERSONA_DIAGNOSTIC_VERSION;
    observation.size = JBCLIENT_PERSONA_DIAGNOSTIC_SIZE;
    copy_result = 0;
    errno = saved_errno;
}
#endif

#ifndef OMIT_COPY
int jbclient_persona_diagnostic_copy(jbclient_persona_diagnostic_v1 *out, uint32_t out_size)
{
    int saved_errno = errno;
    if (!out || out_size != sizeof(observation)) {
        errno = saved_errno;
        return -1;
    }
    if (copy_result == 1) *out = observation;
    errno = saved_errno;
    return copy_result;
}
#endif

void sileo_test_diagnostic_fixture(int kind)
{
    memset(&observation, 0, sizeof(observation));
    observation.version = JBCLIENT_PERSONA_DIAGNOSTIC_VERSION;
    observation.size = JBCLIENT_PERSONA_DIAGNOSTIC_SIZE;
    observation.request_observed = 1;
    observation.pipe_available = 1;
    observation.ipc_called = 1;
    observation.reply_present = 1;
    observation.reply_dictionary = 1;
    observation.result_valid = 1;
    observation.server_stage_valid = 1;
    observation.original_result = -1;
    observation.server_stage = JB_PERSONA_DIAGNOSTIC_ENTITLEMENT_DENIED;
    copy_result = 1;
    switch (kind) {
    case 0: copy_result = 0; break;
    case 1: break;
    case 2:
        observation.ipc_result = 5;
        observation.reply_present = 0;
        observation.reply_dictionary = 0;
        observation.result_valid = 0;
        observation.server_stage_valid = 0;
        observation.original_result = INT64_MIN;
        observation.server_stage = UINT64_MAX;
        break;
    case 3:
        observation.pipe_available = 0;
        observation.ipc_called = 0;
        observation.ipc_result = -123;
        observation.reply_present = 0;
        observation.reply_dictionary = 0;
        observation.result_valid = 0;
        observation.server_stage_valid = 0;
        break;
    case 4: observation.reply_present = 0; break;
    case 5: observation.reply_dictionary = 0; break;
    case 6: observation.result_valid = 0; break;
    case 7: observation.server_stage = UINT64_MAX; break;
    case 8: observation.version = 2; break;
    case 9: observation.size = 64; break;
    case 10: observation.result_valid = 2; break;
    case 11: copy_result = -1; break;
    case 12: observation.server_stage = JB_PERSONA_DIAGNOSTIC_UNKNOWN; break;
    case 13:
        observation.server_stage_valid = 0;
        observation.server_stage = JB_PERSONA_DIAGNOSTIC_ENTITLEMENT_DENIED;
        break;
    case 14: observation.original_result = INT64_MAX; break;
    case 15: observation.original_result = INT64_MIN; break;
    case 16:
        observation.ipc_called = 0;
        observation.ipc_result = -123;
        break;
    case 17: copy_result = 2; break;
    case 18: observation.request_observed = 0; break;
    case 19: observation.server_stage = JB_PERSONA_DIAGNOSTIC_CHILD_NOT_FOUND; break;
    case 20: observation.server_stage = JB_PERSONA_DIAGNOSTIC_CHILD_PATH_FAILED; break;
    case 21: observation.server_stage = JB_PERSONA_DIAGNOSTIC_EXISTING_HELPER_FAILED; break;
    case 22: observation.server_stage = JB_PERSONA_DIAGNOSTIC_COMPLETED; break;
    default: copy_result = -1; break;
    }
}
