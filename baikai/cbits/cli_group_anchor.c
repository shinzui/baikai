/* Reserve a process group after its CLI leader has been reaped. The parent
 * establishes membership before returning; it must not reap the anchor until
 * its final group signal/observation. A dead, unreaped anchor reserves it too.
 * The child runs only async-signal-safe operations: no Haskell or allocation. */
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

int baikai_cli_group_anchor(int group) {
    long limit = sysconf(_SC_OPEN_MAX);
    if (limit < 0) { errno = EINVAL; return -1; }
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        struct sigaction ignore;
        sigset_t empty;
        ignore.sa_handler = SIG_IGN;
        ignore.sa_flags = 0;
        sigemptyset(&ignore.sa_mask);
        sigemptyset(&empty);
        if (sigaction(SIGINT, &ignore, 0) < 0 ||
            sigaction(SIGTERM, &ignore, 0) < 0 ||
            sigprocmask(SIG_SETMASK, &empty, 0) < 0) _exit(127);
        /* Inherited descriptors are never used and are closed before parking.
         * Cancellation may kill this child while it is closing descriptors;
         * its unreaped membership still protects the group's identity. */
#ifdef __linux__
#ifdef SYS_close_range
        if (syscall(SYS_close_range, 0U, ~0U, 0U) < 0)
#endif
#endif
            for (long fd = 0; fd < limit; ++fd) close((int)fd);
        for (;;) pause();
    }
    /* The anchor never execs, so the parent can set its process group here.
     * The CLI leader is still unreaped and no callback yet owns its handle. */
    if (setpgid(child, (pid_t)group) < 0) {
        int saved = errno;
        kill(child, SIGKILL);
        while (waitpid(child, 0, 0) < 0 && errno == EINTR) {}
        errno = saved; return -1;
    }
    return (int)child;
}
