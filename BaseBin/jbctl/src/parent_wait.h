#ifndef JBCTL_PARENT_WAIT_H
#define JBCTL_PARENT_WAIT_H

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// The parent restores its temporary credentials before sending this byte.
// Consume the control arguments so they can never become tool arguments.
static int jbctl_consume_parent_wait(int *argc, char *argv[], int timeout_ms)
{
    if (*argc < 3 || strcmp(argv[*argc - 2], "--waitfor")) return 0;
    char *end = NULL;
    errno = 0;
    long parsed = strtol(argv[*argc - 1], &end, 10);
    if (errno || !end || *end || parsed < 3 || parsed > INT_MAX || timeout_ms <= 0) return EINVAL;
    int fd = (int)parsed;
    *argc -= 2;
    argv[*argc] = NULL;

    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    int64_t deadline = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 + timeout_ms;
    int error = 0;
    for (;;) {
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { error = errno; break; }
        int64_t remaining = deadline - ((int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
        if (remaining <= 0) { error = ETIMEDOUT; break; }
        struct pollfd waiting = { .fd = fd, .events = POLLIN };
        int result = poll(&waiting, 1, (int)remaining);
        if (result < 0) {
            if (errno == EINTR) continue;
            error = errno;
            break;
        }
        if (result == 0) { error = ETIMEDOUT; break; }
        if (waiting.revents & POLLNVAL) { error = EBADF; break; }
        unsigned char token = 0;
        ssize_t count = read(fd, &token, sizeof(token));
        if (count < 0 && errno == EINTR) continue;
        if (count != sizeof(token) || token != 'w') error = count < 0 ? errno : EPROTO;
        break;
    }
    close(fd);
    return error;
}

#endif
