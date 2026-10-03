/* Ordinary, unprivileged POSIX spawn regression. Never executes APT or a helper.
 * The executable launches only its own --probe mode under the current identity.
 */
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

enum { CHANNELS = 4, SCAN_LIMIT = 256 };
static const int targets[CHANNELS] = {1, 2, 5, 6};
static const char *const payloads[CHANNELS] = {
    "stdout-channel\n", "stderr-channel\n", "status-channel\n", "sileo-channel\n"
};

static int open_count(void) {
    int count = 0;
    for (int fd = 0; fd < SCAN_LIMIT; ++fd)
        if (fcntl(fd, F_GETFD) != -1) ++count;
    return count;
}

static void close_owned(int *fd) {
    if (*fd >= 0) {
        (void)close(*fd);
        *fd = -1;
    }
}

static int child_probe(void) {
    int failures = 0;
    for (int fd = 3; fd < SCAN_LIMIT; ++fd) {
        if (fd != 5 && fd != 6 && fcntl(fd, F_GETFD) != -1) failures |= 16;
    }
    for (int channel = 0; channel < CHANNELS; ++channel) {
        size_t length = strlen(payloads[channel]);
        ssize_t written = write(targets[channel], payloads[channel], length);
        if (written != (ssize_t)length) failures |= 1 << channel;
    }
    return failures;
}

static int run_case(const char *executable, int first_fd, bool relocate, bool invalid_action) {
    int pipes[CHANNELS][2];
    int reserved[SCAN_LIMIT];
    int original[CHANNELS][2];
    bool received[CHANNELS] = {false, false, false, false};
    int reserved_count = 0;
    int initial_count = open_count();
    int setup_error = 0;
    int spawn_status = -1;
    int child_exit = -1;
    pid_t pid = -1;
    const char *failed_stage = "none";
    posix_spawn_file_actions_t actions;
    bool actions_ready = false;

    for (int channel = 0; channel < CHANNELS; ++channel) {
        pipes[channel][0] = pipes[channel][1] = -1;
        original[channel][0] = original[channel][1] = -1;
    }

    /* A clean subprocess should inherit only 0, 1, 2. Do not close unknown fds. */
    if (initial_count != 3) {
        setup_error = EBUSY;
        failed_stage = "unexpected inherited descriptor";
        goto cleanup;
    }
    for (int expected = 3; expected < first_fd; ++expected) {
        int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd == -1) {
            setup_error = errno;
            failed_stage = "reserve descriptor";
            goto cleanup;
        }
        reserved[reserved_count++] = fd;
        if (fd != expected) {
            setup_error = EBUSY;
            failed_stage = "descriptor layout";
            goto cleanup;
        }
    }
    for (int channel = 0; channel < CHANNELS; ++channel) {
        if (pipe(pipes[channel]) == -1) {
            setup_error = errno;
            failed_stage = "pipe";
            goto cleanup;
        }
        for (int end = 0; end < 2; ++end) {
            original[channel][end] = pipes[channel][end];
            if (pipes[channel][end] != first_fd + channel * 2 + end) {
                setup_error = EBUSY;
                failed_stage = "pipe descriptor layout";
                goto cleanup;
            }
        }
    }

    if (relocate) {
        /* Relocate both ends before constructing actions. No pipe source can
         * then alias protocol outputs 5 and 6 (or standard outputs 1 and 2).
         */
        for (int channel = 0; channel < CHANNELS; ++channel) {
            for (int end = 0; end < 2; ++end) {
                int replacement = fcntl(pipes[channel][end], F_DUPFD_CLOEXEC, 7);
                if (replacement == -1) {
                    setup_error = errno;
                    failed_stage = "relocate pipe descriptor";
                    goto cleanup;
                }
                close_owned(&pipes[channel][end]);
                pipes[channel][end] = replacement;
            }
        }
    }

    setup_error = posix_spawn_file_actions_init(&actions);
    if (setup_error != 0) {
        failed_stage = "initialize file actions";
        goto cleanup;
    }
    actions_ready = true;
    for (int channel = 0; channel < CHANNELS; ++channel) {
        setup_error = posix_spawn_file_actions_addclose(&actions, pipes[channel][0]);
        if (setup_error != 0) {
            failed_stage = "add read-end close action";
            goto cleanup;
        }
    }
    for (int channel = 0; channel < CHANNELS; ++channel) {
        int source = invalid_action && channel == 2 ? -1 : pipes[channel][1];
        setup_error = posix_spawn_file_actions_adddup2(&actions, source, targets[channel]);
        if (setup_error != 0) {
            failed_stage = "add output duplication action";
            goto cleanup;
        }
    }
    for (int channel = 0; channel < CHANNELS; ++channel) {
        setup_error = posix_spawn_file_actions_addclose(&actions, pipes[channel][1]);
        if (setup_error != 0) {
            failed_stage = "add write-end close action";
            goto cleanup;
        }
    }

    char *const arguments[] = {(char *)executable, "--probe", NULL};
    spawn_status = posix_spawn(&pid, executable, &actions, NULL, arguments, environ);
    if (spawn_status != 0) {
        failed_stage = "ordinary posix_spawn";
        goto cleanup;
    }
    for (int channel = 0; channel < CHANNELS; ++channel) close_owned(&pipes[channel][1]);
    int wait_status = 0;
    pid_t waited;
    do { waited = waitpid(pid, &wait_status, 0); } while (waited == -1 && errno == EINTR);
    if (waited == -1) {
        setup_error = errno;
        failed_stage = "waitpid";
        goto cleanup;
    }
    child_exit = WIFEXITED(wait_status) ? WEXITSTATUS(wait_status) : 128 + WTERMSIG(wait_status);
    for (int channel = 0; channel < CHANNELS; ++channel) {
        char buffer[128];
        size_t used = 0;
        ssize_t result;
        while ((result = read(pipes[channel][0], buffer + used, sizeof(buffer) - used)) != 0) {
            if (result < 0) {
                if (errno == EINTR) continue;
                setup_error = errno;
                failed_stage = "read probe channel";
                goto cleanup;
            }
            used += (size_t)result;
            if (used == sizeof(buffer)) {
                setup_error = EOVERFLOW;
                failed_stage = "unexpected probe output";
                goto cleanup;
            }
        }
        received[channel] = used == strlen(payloads[channel]) &&
            memcmp(buffer, payloads[channel], used) == 0;
    }

cleanup:
    if (actions_ready) {
        int destroyed = posix_spawn_file_actions_destroy(&actions);
        if (destroyed != 0 && setup_error == 0) {
            setup_error = destroyed;
            failed_stage = "destroy file actions";
        }
    }
    for (int channel = 0; channel < CHANNELS; ++channel) {
        close_owned(&pipes[channel][0]);
        close_owned(&pipes[channel][1]);
    }
    for (int index = 0; index < reserved_count; ++index) close_owned(&reserved[index]);
    int final_count = open_count();
    printf("{\"first_pipe_fd\":%d,\"relocated\":%s,\"invalid_action\":%s,"
           "\"original_pipe_fds\":[[%d,%d],[%d,%d],[%d,%d],[%d,%d]],"
           "\"setup_error\":%d,\"failed_stage\":\"%s\",\"spawn_status\":%d,"
           "\"child_exit\":%d,\"channels_received\":[%s,%s,%s,%s],"
           "\"initial_open_fds\":%d,\"final_open_fds\":%d}\n",
           first_fd, relocate ? "true" : "false", invalid_action ? "true" : "false",
           original[0][0], original[0][1], original[1][0], original[1][1],
           original[2][0], original[2][1], original[3][0], original[3][1],
           setup_error, failed_stage, spawn_status, child_exit,
           received[0] ? "true" : "false", received[1] ? "true" : "false",
           received[2] ? "true" : "false", received[3] ? "true" : "false",
           initial_count, final_count);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) return child_probe();
    if (argc != 4) return 64;
    int first_fd = atoi(argv[1]);
    if (first_fd < 3 || first_fd > 64) return 64;
    return run_case(argv[0], first_fd, strcmp(argv[2], "relocated") == 0,
                    strcmp(argv[3], "invalid-action") == 0);
}
