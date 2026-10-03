#include "jb_persona_diagnostic_internal.h"
#include <errno.h>

/* No logging, locks, file operations, transport, or credential work. */
static _Thread_local jbclient_persona_diagnostic_v1 clientObservation;
static _Thread_local jbserver_persona_diagnostic_scope serverObservation;

void jbclient_persona_diagnostic_clear(void)
{
	int savedErrno = errno;
	clientObservation = (jbclient_persona_diagnostic_v1){
		.version = JBCLIENT_PERSONA_DIAGNOSTIC_VERSION,
		.size = JBCLIENT_PERSONA_DIAGNOSTIC_SIZE,
	};
	errno = savedErrno;
}

int jbclient_persona_diagnostic_copy(jbclient_persona_diagnostic_v1 *out, uint32_t out_size)
{
	int savedErrno = errno;
	int result = -1;
	if (out && out_size == JBCLIENT_PERSONA_DIAGNOSTIC_SIZE) {
		*out = clientObservation;
		/* Before the first clear/request, TLS zero initialization means absent. */
		out->version = JBCLIENT_PERSONA_DIAGNOSTIC_VERSION;
		out->size = JBCLIENT_PERSONA_DIAGNOSTIC_SIZE;
		result = out->request_observed ? 1 : 0;
	}
	errno = savedErrno;
	return result;
}

void jbclient_persona_diagnostic_publish(const jbclient_persona_diagnostic_v1 *record)
{
	int savedErrno = errno;
	clientObservation = *record;
	errno = savedErrno;
}

jbserver_persona_diagnostic_scope jbserver_persona_diagnostic_begin(void)
{
	int savedErrno = errno;
	jbserver_persona_diagnostic_scope previous = serverObservation;
	serverObservation = (jbserver_persona_diagnostic_scope){ .active = true };
	errno = savedErrno;
	return previous;
}

uint64_t jbserver_persona_diagnostic_end(jbserver_persona_diagnostic_scope previous)
{
	int savedErrno = errno;
	uint64_t stage = serverObservation.stage;
	serverObservation = previous;
	errno = savedErrno;
	return stage;
}

void jbserver_persona_diagnostic_set_stage(uint64_t stage)
{
	int savedErrno = errno;
	if (serverObservation.active) serverObservation.stage = stage;
	errno = savedErrno;
}
