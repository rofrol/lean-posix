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
#include <signal.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

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
SAME(SIGKILL, 9);
SAME(SA_RESTART, 2);

/* open and fcntl */
SAME(O_RDWR, 2);
SAME(O_CLOEXEC, 0x1000000);
SAME(F_GETFD, 1);
SAME(F_SETFD, 2);
SAME(F_DUPFD_CLOEXEC, 67);
SAME(FD_CLOEXEC, 1);

/* ioctl */
SAME(TIOCSCTTY, 0x20007461UL);

/* wait status */
SAME(_WSTOPPED, 0x7f);

/* struct layouts, as the expressions declare them */
#define AT(type, field, offset) \
    _Static_assert(offsetof(type, field) == (offset), #type "." #field " is at " #offset)

/* { void (*h)(int); unsigned m; int f; } */
_Static_assert(sizeof(struct sigaction) == 16, "struct sigaction is 16 bytes");
AT(struct sigaction, sa_handler, 0);
AT(struct sigaction, sa_mask, 8);
AT(struct sigaction, sa_flags, 12);
_Static_assert(sizeof(sigset_t) == 4, "sigset_t is 32 bits");
