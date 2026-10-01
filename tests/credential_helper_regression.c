#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../BaseBin/libjailbreak/src/credential_helper.h"

#ifndef POSIX_SPAWN_START_SUSPENDED
#error This regression requires macOS suspended posix_spawn support.
#endif

struct prepare_context { pid_t pid; int fail; int calls; };

static int prepare(pid_t pid, void *opaque)
{
    struct prepare_context *context = opaque;
    context->pid = pid;
    context->calls++;
    assert(kill(pid, 0) == 0);
    return context->fail ? EACCES : 0;
}

static void assert_reaped(pid_t pid)
{
    int status;
    errno = 0;
    assert(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD);
    errno = 0;
    assert(kill(pid, 0) == -1 && errno == ESRCH);
}

static void run_case(const char *path, const char *mode, int expected,
    int failPatch, int timeoutMs)
{
    char *argv[] = { (char *)path, "--child", (char *)mode, NULL };
    char *env[] = { NULL };
    struct prepare_context context = { .pid = -1, .fail = failPatch };
    pid_t pid = 123;
    int64_t start = jb_credential_helper_now_ms();
    int result = jb_credential_helper_start(path, argv, env,
        POSIX_SPAWN_START_SUSPENDED, prepare, &context, timeoutMs, &pid);
    assert(result == expected);
    // Every error (including EOF while the writer used to be open in the
    // parent) must finish promptly and kill/reap the child.
    assert(jb_credential_helper_now_ms() - start < timeoutMs + 1500);
    if (expected == 0) {
        assert(pid > 0 && pid == context.pid && context.calls == 1);
        assert(jb_credential_helper_stop(pid) == 0);
        assert_reaped(pid);
    } else {
        assert(pid == -1);
        if (context.pid > 0) assert_reaped(context.pid);
        else assert(context.calls == 0);
    }
    printf("PASS credential helper: %s (%d)\n", mode, expected);
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--child") == 0) {
        if (strcmp(argv[2], "timeout") == 0) {
            for (;;) pause();
        }
        if (strcmp(argv[2], "eof") == 0) {
            close(3);
            return 0;
        }
        unsigned char token = strcmp(argv[2], "wrong-token") == 0
            ? 0 : JB_CREDENTIAL_HELPER_TOKEN;
        if (write(3, &token, 1) != 1) return 1;
        close(3);
        for (;;) pause();
    }
    char path[4096];
    assert(realpath(argv[0], path));
    run_case(path, "success", 0, 0, 500);
    run_case(path, "wrong-token", EPROTO, 0, 500);
    run_case(path, "eof", EPROTO, 0, 500);
    run_case(path, "timeout", ETIMEDOUT, 0, 50);
    run_case(path, "patch-failure", EACCES, 1, 500);
    run_case("/nonexistent/credential-helper", "spawn-failure", ENOENT, 0, 500);

    // Exercise the fd 3 collision case with the descriptor explicitly free.
    close(3);
    run_case(path, "success", 0, 0, 500);
    puts("PASS all credential helper lifecycle regressions");
    return 0;
}
