#ifndef JB_PERSONA_DIAGNOSTIC_INTERNAL_H
#define JB_PERSONA_DIAGNOSTIC_INTERNAL_H

#include "jbclient_persona_diagnostic.h"
#include <stdbool.h>

#define JB_PERSONA_DIAGNOSTIC_REPLY_KEY "persona-diagnostic-stage"

/* Request-local client snapshots are published on return, so a nested request
 * cannot corrupt the outer observation. Unrelated RPCs never publish anything.
 */
/* Always local to the image containing the producer, so an identically named
 * helper embedded in another dylib cannot publish into the wrong TLS record.
 */
__attribute__((visibility("hidden")))
void jbclient_persona_diagnostic_publish(const jbclient_persona_diagnostic_v1 *record);

/* A scope restores the previous thread's state after an existing handler. */
typedef struct jbserver_persona_diagnostic_scope {
	uint64_t stage;
	bool active;
} jbserver_persona_diagnostic_scope;

jbserver_persona_diagnostic_scope jbserver_persona_diagnostic_begin(void);
uint64_t jbserver_persona_diagnostic_end(jbserver_persona_diagnostic_scope previous);
void jbserver_persona_diagnostic_set_stage(uint64_t stage);

#endif
