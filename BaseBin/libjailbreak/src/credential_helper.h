#ifndef JB_CREDENTIAL_HELPER_H
#define JB_CREDENTIAL_HELPER_H

// This lifecycle is shared with the host regression test. The callback must
// patch the suspended child directly; it must not check in with launchd.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define JB_CREDENTIAL_HELPER_TOKEN 0x42
#define JB_CREDENTIAL_HELPER_TIMEOUT_MS 3000

typedef int (*jb_credential_helper_prepare_t)(pid_t pid, void *context);

static inline int64_t jb_credential_helper_now_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static inline int jb_credential_helper_stop(pid_t pid)
{
    if (pid <= 0) return EINVAL;
    // launchd can reap SIGCHLD on another thread. Do not signal an already
    // reaped child's PID, which may now belong to an unrelated process.
    for (;;) {
        int status;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return 0;
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return errno;
        break;
    }
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) return errno;
    int64_t start = jb_credential_helper_now_ms();
    if (start < 0) return errno;
    for (;;) {
        int status;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) return 0;
        if (result < 0 && errno != EINTR) return errno;
        int64_t now = jb_credential_helper_now_ms();
        if (now < 0) return errno;
        if (now - start >= 1000) return ETIMEDOUT;
        poll(NULL, 0, 10);
    }
}

static inline int jb_credential_helper_wait(int fd, int timeoutMs)
{
    int64_t start = jb_credential_helper_now_ms();
    if (start < 0) return errno;
    for (;;) {
        int64_t now = jb_credential_helper_now_ms();
        if (now < 0) return errno;
        int64_t remaining = timeoutMs - (now - start);
        if (remaining <= 0) return ETIMEDOUT;
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int result = poll(&pfd, 1, (int)remaining);
        if (result < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        if (result == 0) continue;
        if (pfd.revents & POLLNVAL) return EBADF;
        if (pfd.revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char token = 0;
            ssize_t count = read(fd, &token, 1);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) return errno;
            if (count != 1 || token != JB_CREDENTIAL_HELPER_TOKEN) return EPROTO;
            return 0;
        }
    }
}

static inline int jb_credential_helper_start(const char *path,
    char *const argv[], char *const envp[], short suspendedFlag,
    jb_credential_helper_prepare_t prepare, void *context,
    int timeoutMs, pid_t *pidOut)
{
    if (!path || !path[0] || !prepare || !pidOut || timeoutMs <= 0) return EINVAL;
    *pidOut = -1;
    int pipeFds[2];
    if (pipe(pipeFds) != 0) return errno;

    // Keep the writer above fd 3: addclose(read) must not close the final
    // handshake descriptor when a caller started with fd 3 available.
    int writer = fcntl(pipeFds[1], F_DUPFD_CLOEXEC, 4);
    int result = writer < 0 ? errno : 0;
    close(pipeFds[1]);
    if (result != 0) { close(pipeFds[0]); return result; }
    if (fcntl(pipeFds[0], F_SETFD, FD_CLOEXEC) != 0) {
        result = errno;
        close(pipeFds[0]); close(writer);
        return result;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actionsReady = 0, attributesReady = 0;
    pid_t pid = -1;
    result = posix_spawn_file_actions_init(&actions);
    if (result == 0) actionsReady = 1;
    if (result == 0) result = posix_spawn_file_actions_addclose(&actions, pipeFds[0]);
    if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, writer, 3);
    if (result == 0) result = posix_spawn_file_actions_addclose(&actions, writer);
    if (result == 0) result = posix_spawnattr_init(&attributes);
    if (result == 0) attributesReady = 1;
    if (result == 0) result = posix_spawnattr_setflags(&attributes, suspendedFlag);
    if (result == 0) result = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    // Closing this before waiting makes early child exits observable as EOF.
    close(writer);

    if (result == 0 && pid <= 0) result = ECHILD;
    if (result == 0) result = prepare(pid, context);
    if (result < 0) result = EIO;
    if (result == 0 && kill(pid, SIGCONT) != 0) result = errno;
    if (result == 0) result = jb_credential_helper_wait(pipeFds[0], timeoutMs);
    close(pipeFds[0]);
    if (result != 0) {
        if (pid > 0) {
            int cleanupResult = jb_credential_helper_stop(pid);
            if (cleanupResult != 0) return cleanupResult;
        }
        return result;
    }
    *pidOut = pid;
    return 0;
}

#endif
