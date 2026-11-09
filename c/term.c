/*
 * The terminal at stdin and stdout for `Posix.termCtl` (Posix/Term.lean, whose
 * doc comment is the contract): the terminal as found and whether the full
 * screen is entered, in two statics, so the state is process-global, and the
 * handler of every signal that ends a process and can be caught.
 */
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include <lean/lean.h>

/* The terminal as found, and whether the full screen is entered (so `saved` is
 * to be put back). `on` is read by the signal handler. */
static struct termios saved;
static volatile sig_atomic_t on = 0;

static const char enter_seq[] = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J";
static const char mouse_seq[] = "\x1b[?1000h\x1b[?1006h";
static const char motion_seq[] = "\x1b[?1003h\x1b[?1006h";
/* Mouse reports off, the pointer shape reset (OSC 22), attributes reset,
 * autowrap and the cursor back, the alternate screen left. */
static const char leave_seq[] =
    "\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b]22;\x1b\\\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l";

/* `LEAN_POSIX_TERMIOS` holds WIRE bytes in lowercase hex, the `struct termios`
 * first and zeros after it. The size is the one every build before this file
 * wrote (its buffer was 16 unsigned longs), kept because a build hands the
 * terminal to the next build it executes, which may be built from either. */
#define WIRE 128
_Static_assert(sizeof(struct termios) <= WIRE, "struct termios fits the hand-over format");

/* Leaves the full screen if it is entered and puts the terminal back as found.
 * Async-signal-safe: `write` and `tcsetattr` only. */
static void leave(void) {
    if (on) {
        (void)write(STDOUT_FILENO, leave_seq, sizeof leave_seq - 1);
        tcsetattr(STDIN_FILENO, TCSANOW, &saved);
        on = 0;
    }
}

/* Leaves, then dies of `sig` with its default action, the handler having reset
 * itself (SA_RESETHAND) and the signal being unblocked (SA_NODEFER). `raise`
 * returns only when the signal is ignored or blocked by then; errno is then put
 * back. A signal arriving while the terminal is restored restores it again
 * before it ends the process. */
static void leave_and_die(int sig) {
    int e = errno;
    leave();
    raise(sig);
    errno = e;
}

static void handler(int sig) { leave_and_die(sig); }

/* The signals that end a process and can be caught. */
static const int ending[] = {
    SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGBUS, SIGSEGV,
    SIGSYS, SIGPIPE, SIGALRM, SIGTERM, SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF, SIGUSR1, SIGUSR2,
};

static uint32_t enter_screen(uint32_t op) {
    if (tcgetattr(STDIN_FILENO, &saved) != 0) return 1;
    struct termios raw = saved;
    cfmakeraw(&raw);
    on = 1;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    (void)write(STDOUT_FILENO, enter_seq, sizeof enter_seq - 1);
    if (op == 0) (void)write(STDOUT_FILENO, mouse_seq, sizeof mouse_seq - 1);
    if (op == 1006) (void)write(STDOUT_FILENO, motion_seq, sizeof motion_seq - 1);
    return 0;
}

static int hex_digit(char c) {
    return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

static uint32_t take_handed(void) {
    const char *h = getenv("LEAN_POSIX_TERMIOS");
    unsigned char wire[WIRE];
    uint32_t r = 1;
    if (h) {
        int n = 0, bad = 0;
        while (!bad && n < WIRE) {
            int hi = hex_digit(h[2 * n]);
            int lo = hi < 0 ? -1 : hex_digit(h[2 * n + 1]);
            if (hi < 0 || lo < 0) bad = 1;
            else wire[n++] = (unsigned char)(hi * 16 + lo);
        }
        if (!bad && !h[2 * n]) {
            memcpy(&saved, wire, sizeof saved);
            on = 1;
            r = 0;
        }
    }
    unsetenv("LEAN_POSIX_TERMIOS");
    return r;
}

static uint32_t hand_over(void) {
    static const char hex[] = "0123456789abcdef";
    unsigned char wire[WIRE] = {0};
    char h[WIRE * 2 + 1];
    memcpy(wire, &saved, sizeof saved);
    for (int i = 0; i < WIRE; i++) {
        h[2 * i] = hex[wire[i] >> 4];
        h[2 * i + 1] = hex[wire[i] & 15];
    }
    h[sizeof h - 1] = 0;
    return on && setenv("LEAN_POSIX_TERMIOS", h, 1) == 0 ? 0 : 1;
}

static void install(void) {
    struct sigaction a;
    memset(&a, 0, sizeof a);
    a.sa_handler = handler;
    sigemptyset(&a.sa_mask);
    a.sa_flags = SA_RESETHAND | SA_NODEFER;
    for (size_t i = 0; i < sizeof ending / sizeof ending[0]; i++) sigaction(ending[i], &a, NULL);
    signal(SIGTSTP, SIG_IGN);
}

LEAN_EXPORT lean_obj_res lean_posix_term_ctl(uint32_t op) {
    uint32_t r = 0;
    if (op == 0 || op == 1005 || op == 1006) r = enter_screen(op);
    else if (op == 1000) leave();
    else if (op == 1001) install();
    else if (op == 1002) r = take_handed();
    else if (op == 1003) r = hand_over();
    else if (op == 1004) unsetenv("LEAN_POSIX_TERMIOS");
    else leave_and_die((int)op);
    return lean_io_result_mk_ok(lean_box_uint32(r));
}
