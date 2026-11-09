/*
 * The numbers and struct layouts that the `@[extern c inline]` expressions in
 * Posix/ write by hand, each checked against the macOS SDK's own declaration, so
 * a wrong one fails the build instead of running as undefined behavior. Nothing
 * here is linked: the file holds only static assertions. A number an expression
 * starts using that has a header name gets its assertion here in the same
 * change; each module's header comment lists the numbers it uses.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stddef.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/filio.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>

#define SAME(name, value) _Static_assert((name) == (value), #name " is " #value)

/* errnos */
SAME(EPERM, 1);
SAME(ENOENT, 2);
SAME(ESRCH, 3);
SAME(EINTR, 4);
SAME(EIO, 5);
SAME(EBADF, 9);
SAME(EACCES, 13);
SAME(EEXIST, 17);
SAME(ENOTDIR, 20);
SAME(EISDIR, 21);
SAME(EINVAL, 22);
SAME(ENOTTY, 25);
SAME(EWOULDBLOCK, 35);

/* signals and their dispositions */
SAME(SIGHUP, 1);
SAME(SIGINT, 2);
SAME(SIGQUIT, 3);
SAME(SIGKILL, 9);
SAME(SIGPIPE, 13);
SAME(SIGTERM, 15);
SAME(SIGSTOP, 17);
SAME(SIGTSTP, 18);
SAME(SIGWINCH, 28);
SAME(NSIG, 32);
SAME(SA_RESTART, 2);

/* open and fcntl */
SAME(O_RDONLY, 0);
SAME(O_RDWR, 2);
SAME(O_NONBLOCK, 4);
SAME(O_CREAT, 0x200);
SAME(O_EVTONLY, 0x8000);
SAME(O_NOCTTY, 0x20000);
SAME(O_DIRECTORY, 0x100000);
SAME(O_CLOEXEC, 0x1000000);
SAME(F_GETFD, 1);
SAME(F_SETFD, 2);
SAME(F_GETFL, 3);
SAME(F_SETFL, 4);
SAME(F_DUPFD_CLOEXEC, 67);
SAME(FD_CLOEXEC, 1);

/* flock */
SAME(LOCK_EX, 2);
SAME(LOCK_NB, 4);

/* ioctl and termios */
SAME(FIONREAD, 0x4004667fUL);
SAME(TIOCGWINSZ, 0x40087468UL);
SAME(TIOCSWINSZ, 0x80087467UL);
SAME(TIOCSCTTY, 0x20007461UL);
SAME(TCSAFLUSH, 2);

/* kqueue */
SAME(EVFILT_READ, -1);
SAME(EVFILT_VNODE, -4);
SAME(EVFILT_PROC, -5);
SAME(EVFILT_SIGNAL, -6);
SAME(EV_ADD, 1);
SAME(EV_DELETE, 2);
SAME(EV_ONESHOT, 0x10);
SAME(EV_CLEAR, 0x20);
SAME(EV_EOF, 0x8000);
SAME(NOTE_DELETE, 1);
SAME(NOTE_WRITE, 2);
SAME(NOTE_EXTEND, 4);
SAME(NOTE_RENAME, 0x20);
SAME(NOTE_EXIT, 0x80000000U);

/* clocks, resources, process information, wait status */
SAME(CLOCK_MONOTONIC, 6);
SAME(RUSAGE_SELF, 0);
SAME(PROC_PIDTBSDINFO, 3);
SAME(_WSTOPPED, 0x7f);

/* struct layouts, as the expressions declare them */
#define AT(type, field, offset) \
    _Static_assert(offsetof(type, field) == (offset), #type "." #field " is at " #offset)

/* { unsigned long ident; short filter; unsigned short flags; unsigned fflags;
 *   long data; void* udata; } */
_Static_assert(sizeof(struct kevent) == 32, "struct kevent is 32 bytes");
AT(struct kevent, ident, 0);
AT(struct kevent, filter, 8);
AT(struct kevent, flags, 10);
AT(struct kevent, fflags, 12);
AT(struct kevent, data, 16);
AT(struct kevent, udata, 24);
_Static_assert(sizeof(((struct kevent *)0)->filter) == 2 && sizeof(((struct kevent *)0)->fflags) == 4,
               "kevent's filter is 16 bits, fflags 32");

/* { void (*h)(int); unsigned m; int f; } */
_Static_assert(sizeof(struct sigaction) == 16, "struct sigaction is 16 bytes");
AT(struct sigaction, sa_handler, 0);
AT(struct sigaction, sa_mask, 8);
AT(struct sigaction, sa_flags, 12);
_Static_assert(sizeof(sigset_t) == 4, "sigset_t is 32 bits");

/* four unsigned shorts, rows first */
_Static_assert(sizeof(struct winsize) == 8, "struct winsize is 8 bytes");
AT(struct winsize, ws_row, 0);
AT(struct winsize, ws_col, 2);

/* { long s; int us; } and { long s; long ns; } */
_Static_assert(sizeof(struct timeval) == 16 && sizeof(((struct timeval *)0)->tv_usec) == 4,
               "struct timeval is a long and an int");
AT(struct timeval, tv_sec, 0);
AT(struct timeval, tv_usec, 8);
_Static_assert(sizeof(struct timespec) == 16, "struct timespec is two longs");
AT(struct timespec, tv_sec, 0);
AT(struct timespec, tv_nsec, 8);

/* `fstat64` and `stat64` into 18 or 32 unsigned long longs: st_dev (32 bits) at
 * 0, st_ino at 8, st_size at 96. Their `struct stat64` is the SDK's `struct
 * stat` with 64-bit inodes: the only one on arm64, which declares no `struct
 * stat64`, and the default on x86_64. */
_Static_assert(sizeof(struct stat) == 144, "struct stat is 144 bytes");
AT(struct stat, st_dev, 0);
_Static_assert(sizeof(((struct stat *)0)->st_dev) == 4, "st_dev is 32 bits");
AT(struct stat, st_ino, 8);
AT(struct stat, st_size, 96);

/* `getrusage` into 40 longs, the peak resident set the fifth */
_Static_assert(sizeof(struct rusage) <= 40 * sizeof(long), "struct rusage fits 40 longs");
AT(struct rusage, ru_maxrss, 4 * sizeof(long));

/* `proc_pidinfo` into 136 bytes */
_Static_assert(sizeof(struct proc_bsdinfo) == 136, "struct proc_bsdinfo is 136 bytes");
AT(struct proc_bsdinfo, pbi_start_tvsec, 120);
AT(struct proc_bsdinfo, pbi_start_tvusec, 128);

/* `cfmakeraw` into 32 unsigned longs (openPty) */
_Static_assert(sizeof(struct termios) <= 32 * sizeof(unsigned long), "struct termios fits openPty's buffer");
