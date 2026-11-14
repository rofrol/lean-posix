/*
 * The pty bindings of Posix/Pty.lean, whose doc comments are the contract:
 * `struct termios`, `struct winsize` and every constant come from the SDK's
 * headers.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#include <lean/lean.h>

static lean_object *pair(uint32_t a, uint32_t b) {
    lean_object *p = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(p, 0, lean_box_uint32(a));
    lean_ctor_set(p, 1, lean_box_uint32(b));
    return p;
}

LEAN_EXPORT lean_obj_res lean_posix_open_pty(void) {
    struct termios t = {0};
    cfmakeraw(&t);
    char name[128];
    int s = -1;
    int m = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (m >= 0 && (grantpt(m) != 0 || unlockpt(m) != 0 || ptsname_r(m, name, sizeof name) != 0 ||
                   (s = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)) < 0 || tcsetattr(s, TCSAFLUSH, &t) != 0)) {
        if (s >= 0) close(s);
        close(m);
        m = -1;
        s = -1;
    }
    return lean_io_result_mk_ok(pair((uint32_t)m, (uint32_t)s));
}

LEAN_EXPORT lean_obj_res lean_posix_login_tty(uint32_t fd) {
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)login_tty((int)fd)));
}

LEAN_EXPORT lean_obj_res lean_posix_win_size(void) {
    struct winsize w = {0};
    int ok = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_row > 0 && w.ws_col > 0;
    return lean_io_result_mk_ok(pair(ok ? w.ws_row : 24, ok ? w.ws_col : 80));
}

LEAN_EXPORT lean_obj_res lean_posix_win_size_raw(uint32_t fd) {
    struct winsize w = {0};
    uint64_t r = ioctl((int)fd, TIOCGWINSZ, &w) == 0 ? ((uint64_t)w.ws_row << 16) | w.ws_col
                                                     : (1ull << 63) | (uint32_t)errno;
    return lean_io_result_mk_ok(lean_box_uint64(r));
}

LEAN_EXPORT lean_obj_res lean_posix_set_win_size(uint32_t fd, uint32_t rows, uint32_t cols) {
    struct winsize w = {0};
    w.ws_row = (unsigned short)rows;
    w.ws_col = (unsigned short)cols;
    return lean_io_result_mk_ok(lean_box_uint32(ioctl((int)fd, TIOCSWINSZ, &w) == 0 ? 0u : (uint32_t)errno));
}
