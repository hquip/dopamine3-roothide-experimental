/*
 * Offline macOS regression harness for the actual jbserver.c dispatcher.
 * It uses real libxpc pipes and Mach receive rights, but no device, kernel,
 * credentials, or jailbreak activation. The RootHide filter and test-domain
 * permission/handler are fixtures; production reply and routing code is real.
 *
 * Build from the repository root after BaseBin/.include exists:
 *   xcrun --sdk macosx clang -std=gnu11 -fblocks -Wall -Wextra \
 *     -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
 *     -IBaseBin/libjailbreak/src -idirafter BaseBin/.include \
 *     tests/jbserver_private_pipe_regression.c -lxpc -lbsm \
 *     -o /tmp/jbserver-private-pipe-test
 *   /tmp/jbserver-private-pipe-test
 */

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/param.h>
#include <unistd.h>
#include <mach/mach.h>
#include <bsm/libbsm.h>
#include <xpc/xpc.h>
#include <xpc_private.h>

/* The normal util.h umbrella is intentionally skipped by this fixture. */
extern pid_t audit_token_to_pid(audit_token_t token);
extern uid_t audit_token_to_euid(audit_token_t token);

/* jbserver.c only needs these two hooks from the large umbrella headers. */
#define LJB_UTIL_H
#define ROOTHIDER_H
#include "jbserver.h"

static atomic_int filter_calls;
static atomic_int permission_calls;
static atomic_int handler_calls;
static atomic_int reply_attempts;
static atomic_int reply_send_errors;
static atomic_bool deny_permission;
static atomic_int requested_handler_result;

static void require_condition(bool condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void timed_out(int signal_number)
{
    (void)signal_number;
    static const char message[] = "FAIL: local XPC test timed out\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

bool roothide_handle_xpc_msg(xpc_object_t message)
{
    atomic_fetch_add(&filter_calls, 1);
    return xpc_dictionary_get_bool(message, "fixture-filter-deny");
}

static bool fixture_permission(audit_token_t token)
{
    atomic_fetch_add(&permission_calls, 1);
    return audit_token_to_pid(token) == getpid()
        && audit_token_to_euid(token) == geteuid()
        && !atomic_load(&deny_permission);
}

static int fixture_handler(audit_token_t *token, uint64_t nonce, uint64_t *echo)
{
    require_condition(audit_token_to_pid(*token) == getpid(), "handler audit PID changed");
    require_condition(audit_token_to_euid(*token) == geteuid(), "handler audit UID changed");
    atomic_fetch_add(&handler_calls, 1);
    *echo = nonce;
    return atomic_load(&requested_handler_result);
}

static int counted_xpc_pipe_routine_reply(xpc_object_t reply)
{
    require_condition(reply != NULL, "attempted to send a NULL reply");
    atomic_fetch_add(&reply_attempts, 1);
    int result = xpc_pipe_routine_reply(reply);
    if (result != 0) atomic_fetch_add(&reply_send_errors, 1);
    return result;
}

/* Compile the production dispatcher into this test while counting replies. */
#include "jb_persona_diagnostic.c"
#define xpc_pipe_routine_reply counted_xpc_pipe_routine_reply
#include "jbserver.c"
#undef xpc_pipe_routine_reply

static struct jbserver_domain fixture_domain = {
    .permissionHandler = fixture_permission,
    .actions = {
        {
            .handler = fixture_handler,
            .args = (jbserver_arg[]) {
                { .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN },
                { .name = "nonce", .type = JBS_TYPE_UINT64 },
                { .name = "echo", .type = JBS_TYPE_UINT64, .out = true },
                { 0 },
            },
        },
        { 0 },
    },
};

static struct jbserver_impl fixture_server = {
    .maxDomain = 1,
    .domains = (struct jbserver_domain *[]) { &fixture_domain, NULL },
};

struct receive_context {
    mach_port_t port;
    int receive_result;
    int dispatch_result;
};

static void *receive_one(void *opaque)
{
    struct receive_context *context = opaque;
    xpc_object_t request = NULL;
    context->receive_result = xpc_pipe_receive(context->port, &request);
    if (context->receive_result == 0) {
        require_condition(request != NULL, "successful receive produced NULL");
        context->dispatch_result =
            jbserver_received_xpc_message_with_error_reply(&fixture_server, request);
        xpc_release(request);
    }
    return NULL;
}

static void reset_counters(void)
{
    atomic_store(&filter_calls, 0);
    atomic_store(&permission_calls, 0);
    atomic_store(&handler_calls, 0);
    atomic_store(&reply_attempts, 0);
    atomic_store(&reply_send_errors, 0);
    atomic_store(&deny_permission, false);
    atomic_store(&requested_handler_result, 0);
}

static xpc_object_t request_for(uint64_t domain, uint64_t action)
{
    xpc_object_t request = xpc_dictionary_create_empty();
    xpc_dictionary_set_uint64(request, "jb-domain", domain);
    xpc_dictionary_set_uint64(request, "action", action);
    xpc_dictionary_set_uint64(request, "nonce", UINT64_C(0x735041524b));
    return request;
}

static void roundtrip(const char *name, xpc_object_t request,
                      int expected_result, int expected_handler_calls)
{
    struct receive_context context = { .receive_result = -999, .dispatch_result = -999 };
    require_condition(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &context.port)
                      == KERN_SUCCESS, "allocate local receive port");
    require_condition(mach_port_insert_right(mach_task_self(), context.port, context.port,
                                             MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS,
                      "insert local send right");
    pthread_t receiver;
    require_condition(pthread_create(&receiver, NULL, receive_one, &context) == 0,
                      "start local receiver");
    xpc_object_t pipe = xpc_pipe_create_from_port(context.port, 0);
    require_condition(pipe != NULL, "create local XPC pipe");
    xpc_object_t reply = NULL;
    alarm(10);
    int transport_result = xpc_pipe_routine(pipe, request, &reply);
    require_condition(pthread_join(receiver, NULL) == 0, "join local receiver");
    alarm(0);
    require_condition(context.receive_result == 0, "local receive failed");
    require_condition(transport_result == 0 && reply != NULL, "no correlated XPC reply");
    require_condition(xpc_get_type(xpc_dictionary_get_value(reply, "result")) == XPC_TYPE_INT64,
                      "reply omitted typed result");
    require_condition(xpc_dictionary_get_int64(reply, "result") == expected_result,
                      "unexpected reply result");
    require_condition(atomic_load(&handler_calls) == expected_handler_calls,
                      "handler invocation count");
    require_condition(atomic_load(&reply_attempts) == 1, "reply must be sent exactly once");
    require_condition(atomic_load(&reply_send_errors) == 0, "reply transport failed");
    require_condition(atomic_load(&filter_calls) == 1, "filter must run once");
    if (expected_handler_calls) {
        require_condition(context.dispatch_result == 0, "handled request status was not zero");
        require_condition(xpc_dictionary_get_uint64(reply, "echo") == UINT64_C(0x735041524b),
                          "successful action output missing");
    }
    xpc_release(reply);
    xpc_release(pipe);
    xpc_release(request);
    require_condition(mach_port_destroy(mach_task_self(), context.port) == KERN_SUCCESS,
                      "destroy local port");
    printf("PASS: %s\n", name);
}

int main(void)
{
    signal(SIGALRM, timed_out);
    reset_counters();
    roundtrip("allowed request", request_for(1, 1), 0, 1);
    reset_counters();
    atomic_store(&requested_handler_result, EIO);
    roundtrip("handler failure preserves one reply", request_for(1, 1), EIO, 1);
    reset_counters();
    atomic_store(&deny_permission, true);
    roundtrip("permission denial", request_for(1, 1), EPERM, 0);
    reset_counters();
    xpc_object_t filtered = request_for(1, 1);
    xpc_dictionary_set_bool(filtered, "fixture-filter-deny", true);
    roundtrip("RootHide filter denial", filtered, EPERM, 0);
    reset_counters();
    roundtrip("unknown domain", request_for(2, 1), EINVAL, 0);
    reset_counters();
    roundtrip("unknown action", request_for(1, 2), EINVAL, 0);
    reset_counters();
    xpc_object_t missing = request_for(1, 1);
    xpc_dictionary_set_value(missing, "action", NULL);
    roundtrip("missing action", missing, EINVAL, 0);
    reset_counters();
    xpc_object_t wrong_type = request_for(1, 1);
    xpc_dictionary_set_string(wrong_type, "action", "1");
    roundtrip("wrong action type", wrong_type, EINVAL, 0);

    reset_counters();
    xpc_object_t no_reply = request_for(1, 1);
    bool (*saved_permission)(audit_token_t) = fixture_domain.permissionHandler;
    fixture_domain.permissionHandler = NULL;
    int result = jbserver_received_xpc_message_with_error_reply(&fixture_server, no_reply);
    fixture_domain.permissionHandler = saved_permission;
    require_condition(result != 0 && atomic_load(&handler_calls) == 0,
                      "no-reply input executed a privileged action");
    require_condition(atomic_load(&reply_attempts) == 0, "no-reply input sent a reply");
    xpc_release(no_reply);
    puts("PASS: valid no-reply dictionary rejected safely");

    reset_counters();
    xpc_object_t non_dictionary = xpc_array_create_empty();
    result = jbserver_received_xpc_message_with_error_reply(&fixture_server, non_dictionary);
    require_condition(result != 0 && atomic_load(&handler_calls) == 0
                      && atomic_load(&reply_attempts) == 0,
                      "non-dictionary input was not rejected safely");
    xpc_release(non_dictionary);
    puts("PASS: non-dictionary rejected safely");
    puts("All local libxpc transport checks passed; no device compatibility claim.");
    return 0;
}
