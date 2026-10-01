#ifndef ROOTHIDE_SPAWN_CLEANUP_H
#define ROOTHIDE_SPAWN_CLEANUP_H

#include <dispatch/dispatch.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include "process_identity.h"

// Cleanup is only for a successfully spawned child owned by this process.
// Keep a delayed exit out of launchd's spawn path; the child cannot survive
// a failed patch merely because its requester has stopped waiting for it.
static inline void roothide_kill_and_reap_child(pid_t pid)
{
    if (pid <= 0) return;

    int savedErrno = errno;
    pid_t waited;
    do {
        waited = waitpid(pid, NULL, WNOHANG);
    } while (waited == -1 && errno == EINTR);
    // A SIGCHLD handler may have already reaped it. Never signal a PID
    // unless it still denotes an unreaped child owned by this process.
    if (waited != 0) {
        errno = savedErrno;
        return;
    }

    uint64_t childUniqueID = roothide_process_unique_id(pid);
    if (kill(pid, SIGKILL) == 0 || errno == ESRCH) {
        do {
            waited = waitpid(pid, NULL, WNOHANG);
        } while (waited == -1 && errno == EINTR);

        if (waited == 0 && childUniqueID != 0) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                // Never wait for a later child that reused this PID after
                // another SIGCHLD handler reaped the failed spawn.
                for (int attempts = 0; attempts < 100; attempts++) {
                    if (roothide_process_unique_id(pid) != childUniqueID) break;
                    pid_t reaped = waitpid(pid, NULL, WNOHANG);
                    if (reaped > 0 || (reaped == -1 && errno != EINTR)) break;
                    usleep(10000);
                }
            });
        }
    }
    errno = savedErrno;
}

#endif
