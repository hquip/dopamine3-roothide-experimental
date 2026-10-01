#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/wait.h>

#include "../BaseBin/jbctl/src/parent_wait.h"

static int run_wait_case(int read_fd, int timeout_ms)
{
    char descriptor[24];
    snprintf(descriptor, sizeof(descriptor), "%d", read_fd);
    char *arguments[] = { "jbctl", "internal", "run_tool", "/bootstrap/usr/bin/uicache", "-a", "--waitfor", descriptor, NULL };
    int count = 7;
    int result = jbctl_consume_parent_wait(&count, arguments, timeout_ms);
    assert(count == 5 && arguments[5] == NULL);
    assert(fcntl(read_fd, F_GETFD) == -1 && errno == EBADF);
    return result;
}

int main(void)
{
    int pipes[2];
    assert(pipe(pipes) == 0);
    assert(write(pipes[1], "w", 1) == 1);
    close(pipes[1]);
    assert(run_wait_case(pipes[0], 500) == 0);

    assert(pipe(pipes) == 0);
    assert(write(pipes[1], "x", 1) == 1);
    close(pipes[1]);
    assert(run_wait_case(pipes[0], 500) == EPROTO);

    assert(pipe(pipes) == 0);
    close(pipes[1]);
    assert(run_wait_case(pipes[0], 500) == EPROTO);

    assert(pipe(pipes) == 0);
    assert(run_wait_case(pipes[0], 40) == ETIMEDOUT);
    close(pipes[1]);

    assert(pipe(pipes) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(pipes[0]);
        usleep(20000);
        _exit(write(pipes[1], "w", 1) == 1 ? 0 : 1);
    }
    close(pipes[1]);
    assert(run_wait_case(pipes[0], 500) == 0);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);

    char *invalid[] = { "jbctl", "internal", "--waitfor", "3bad", NULL };
    int count = 4;
    assert(jbctl_consume_parent_wait(&count, invalid, 50) == EINVAL);
    char *ordinary[] = { "jbctl", "respring", NULL };
    count = 2;
    assert(jbctl_consume_parent_wait(&count, ordinary, 50) == 0 && count == 2);
    puts("PASS: parent cleanup handshake, argument stripping, delayed token, EOF, wrong token, timeout, invalid fd argument");
    return 0;
}
