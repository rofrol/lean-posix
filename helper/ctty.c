/*
 * lean-posix-ctty: the helper through which `Posix.trySpawn` starts a program
 * on a controlling terminal (`ctty`), since macOS's posix_spawn has no
 * attribute for one (docs/decisions/0001-ctty-helper.md), or one that records
 * its own identity before it runs (`record`, docs/decisions/0002-spawn-record.md).
 * Lake builds it as the target `lean-posix-ctty`; the library looks for it next
 * to `IO.appPath`.
 *
 * Protocol version 2, which c/spawn.c speaks too:
 *
 *     lean-posix-ctty --lean-posix-ctty-v2 FD SETSID CTTY RECORD N PATH... ARG...
 *
 * spawned with the child's stdin, stdout and stderr already in place and the
 * child's environment. FD is the write end of the result pipe, inherited; SETSID
 * and CTTY are 1 or 0; RECORD is 0 or an inherited descriptor above 2; then N
 * paths to try in order and the program's arguments. The helper makes FD
 * close-on-exec and writes the greeting `lpctty2\n` to it; then it calls setsid
 * (if SETSID is 1) and ioctl(0, TIOCSCTTY) (if CTTY is 1); with RECORD, it
 * writes the line `PID SID START\n` (decimal: its pid, which the program keeps,
 * its session, and its start in microseconds since the epoch from proc_pidinfo,
 * as `Posix.processStart` gives it) to RECORD, fsyncs it and closes it, so the
 * program never holds it; then it execve's each path in turn, as `trySpawn`
 * without ctty tries them. On a failure it writes a record of two native ints,
 * the stage (0 the exec, 3 setsid, 7 TIOCSCTTY, 9 the identity record) and the
 * errno, and exits 127, the program not run; a successful exec closes FD with
 * no record.
 * Any other first argument, or a malformed one, is refused with a line on
 * stderr and exit status 127, before any greeting, so the library finds a
 * helper of another version by the greeting's absence. That stderr is the
 * child's already, so the line says there why the program did not start.
 *
 * Single-threaded and linked with libSystem only.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <unistd.h>

#define CTTY_MARKER "--lean-posix-ctty-v2"
#define CTTY_GREETING "lpctty2\n"

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

static int flag(const char *s) { return strcmp(s, "0") == 0 || strcmp(s, "1") == 0; }

/* Writes this process's `PID SID START\n` to `fd`, fsyncs and closes it: 0, or
   the errno of what failed (`fd` closed in any case). */
static int publish(int fd) {
    struct proc_bsdinfo info;
    char line[80];
    pid_t pid = getpid(), sid = getsid(0);
    int e = 0;
    if (sid < 0) e = errno;
    else if ((errno = 0), proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info)
        e = errno != 0 ? errno : EIO;
    if (e == 0) {
        int k = snprintf(line, sizeof line, "%d %d %llu\n", (int)pid, (int)sid,
                         (unsigned long long)info.pbi_start_tvsec * 1000000ull + info.pbi_start_tvusec);
        int r;
        if (write_all(fd, line, (size_t)k) < 0) e = errno;
        else {
            do r = fsync(fd);
            while (r < 0 && errno == EINTR);
            if (r < 0) e = errno;
        }
    }
    if (close(fd) < 0 && e == 0) e = errno;
    return e;
}

int main(int argc, char **argv) {
    long fd = argc >= 7 ? number(argv[2]) : -1;
    long record = argc >= 7 ? number(argv[5]) : -1;
    long n = argc >= 7 ? number(argv[6]) : -1;
    if (argc < 7 || strcmp(argv[1], CTTY_MARKER) != 0 || fd < 3 || n < 0 || n > argc - 7 || !flag(argv[3])
        || !flag(argv[4]) || record < 0 || (record > 0 && record < 3) || record == fd) {
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
    if (stage == 0 && argv[4][0] == '1' && ioctl(0, TIOCSCTTY, 0) < 0) {
        stage = 7;
        err = errno;
    }
    if (stage == 0 && record > 0 && (err = publish((int)record)) != 0) stage = 9;
    if (stage == 0) {
        char **paths = argv + 7, **args = argv + 7 + n;
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
