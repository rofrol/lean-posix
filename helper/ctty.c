/*
 * lean-posix-ctty: the helper through which `Posix.trySpawn ... (ctty := true)`
 * starts a program on a controlling terminal, since macOS's posix_spawn has no
 * attribute for one (docs/decisions/0001-ctty-helper.md). Lake builds it as the
 * target `lean-posix-ctty`; the library looks for it next to `IO.appPath`.
 *
 * Protocol version 1, which c/spawn.c speaks too:
 *
 *     lean-posix-ctty --lean-posix-ctty-v1 FD SETSID N PATH... ARG...
 *
 * spawned with the child's stdin, stdout and stderr already in place and the
 * child's environment. FD is the write end of the result pipe, inherited; SETSID
 * is 1 or 0; then N paths to try in order and the program's arguments. The
 * helper makes FD close-on-exec and writes the greeting `lpctty1\n` to it; then
 * it calls setsid (if SETSID is 1) and ioctl(0, TIOCSCTTY) and execve's each
 * path in turn, as `trySpawn` without ctty tries them. On a failure it writes
 * a record of two native ints, the stage (0 the exec, 3 setsid, 7 TIOCSCTTY)
 * and the errno, and exits 127; a successful exec closes FD with no record.
 * Any other first argument, or a malformed one, is refused with a line on
 * stderr and exit status 127, before any greeting, so the library finds a
 * helper of another version by the greeting's absence. That stderr is the
 * child's already, so the line says there why the program did not start.
 *
 * Single-threaded and linked with libSystem only.
 */
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define CTTY_MARKER "--lean-posix-ctty-v1"
#define CTTY_GREETING "lpctty1\n"

extern char **environ;

/* A decimal number of at most 9 digits, or -1. */
static long number(const char *s) {
    long n = 0;
    size_t i = 0;
    for (; s[i] && i < 9; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        n = n * 10 + (s[i] - '0');
    }
    return i == 0 || s[i] ? -1 : n;
}

static int write_all(int fd, const void *buf, size_t n) {
    size_t put = 0;
    while (put < n) {
        ssize_t r = write(fd, (const char *)buf + put, n - put);
        if (r > 0) put += (size_t)r;
        else if (r < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    long fd = argc >= 5 ? number(argv[2]) : -1;
    long n = argc >= 5 ? number(argv[4]) : -1;
    if (argc < 5 || strcmp(argv[1], CTTY_MARKER) != 0 || fd < 3 || n < 0 || n > argc - 5
        || (strcmp(argv[3], "0") != 0 && strcmp(argv[3], "1") != 0)) {
        static const char msg[] = "lean-posix-ctty: not started by lean-posix with protocol " CTTY_MARKER "\n";
        write_all(2, msg, sizeof msg - 1);
        return 127;
    }
    int w = (int)fd;
    if (fcntl(w, F_SETFD, FD_CLOEXEC) < 0 || write_all(w, CTTY_GREETING, 8) < 0) return 127;
    int stage = 0, err = 0;
    if (argv[3][0] == '1' && setsid() < 0) {
        stage = 3;
        err = errno;
    }
    if (stage == 0 && ioctl(0, TIOCSCTTY, 0) < 0) {
        stage = 7;
        err = errno;
    }
    if (stage == 0) {
        char **paths = argv + 5, **args = argv + 5 + n;
        int seen = 0, stop = 0;
        for (long i = 0; i < n && !stop; i++) {
            execve(paths[i], args, environ);
            if (errno == EACCES) seen = 1;
            else if (errno != ENOENT && errno != ENOTDIR) {
                err = errno;
                stop = 1;
            }
        }
        if (!stop) err = seen ? EACCES : ENOENT;
    }
    int rec[2] = {stage, err};
    write_all(w, rec, sizeof rec);
    return 127;
}
