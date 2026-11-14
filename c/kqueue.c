/*
 * The kqueue bindings of Posix/Kqueue.lean, whose doc comments are the
 * contract: `struct kevent`, `struct sigaction` and every constant come from
 * the SDK's headers.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/event.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <lean/lean.h>

/* Applies one change to `kq`: kevent's result. */
static int change(int kq, uintptr_t ident, int16_t filter, uint16_t flags, uint32_t fflags, void *udata) {
    struct kevent c;
    EV_SET(&c, ident, filter, flags, fflags, 0, udata);
    return kevent(kq, &c, 1, NULL, 0, NULL);
}

/* Blocks for one event, resuming when a signal interrupts the wait: kevent's
 * result. */
static int next(int kq, struct kevent *e) {
    int n;
    do n = kevent(kq, NULL, 0, e, 1, NULL);
    while (n < 0 && errno == EINTR);
    return n;
}

static int open_events(const char *path) { return open(path, O_EVTONLY | O_CLOEXEC); }

LEAN_EXPORT lean_obj_res lean_posix_open_events(b_lean_obj_arg path) {
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)open_events(lean_string_cstr(path))));
}

LEAN_EXPORT lean_obj_res lean_posix_watch_session(uint32_t pid, uint32_t fd32, uint32_t dir) {
    int kq = kqueue();
    fcntl(kq, F_SETFD, FD_CLOEXEC);
    int fd = (int)fd32;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    change(kq, (uintptr_t)fd, EVFILT_READ, EV_ADD, 0, NULL);
    if ((int)dir >= 0) change(kq, dir, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_WRITE, NULL);
    uint32_t gone = change(kq, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, NULL) != 0 ? 0x80000000u : 0;
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)kq | gone));
}

LEAN_EXPORT lean_obj_res lean_posix_next_event(uint32_t kq) {
    struct kevent e;
    int n = next((int)kq, &e);
    uint32_t r = n != 1 || e.filter == EVFILT_PROC     ? 2
                 : e.filter == EVFILT_VNODE             ? 3
                 : (e.flags & EV_EOF) && e.data == 0    ? 1
                                                        : 0;
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_unwatch_read(uint32_t kq, uint32_t fd) {
    change((int)kq, fd, EVFILT_READ, EV_DELETE, 0, NULL);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_kq_open(void) {
    int k = kqueue();
    fcntl(k, F_SETFD, FD_CLOEXEC);
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)k));
}

LEAN_EXPORT lean_obj_res lean_posix_kq_setup(uint32_t kq) {
    struct kevent c[2];
    EV_SET(&c[0], STDIN_FILENO, EVFILT_READ, EV_ADD, 0, 0, NULL);
    EV_SET(&c[1], SIGWINCH, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    kevent((int)kq, c, 2, NULL, 0, NULL);
    return lean_io_result_mk_ok(lean_box(0));
}

/* `catchSignals`' handler: it does nothing, so the signal only arrives on the
 * kqueue that watches it. */
static void caught(int sig) { (void)sig; }

LEAN_EXPORT lean_obj_res lean_posix_catch_signals(uint32_t kq, b_lean_obj_arg sigs) {
    struct sigaction a;
    memset(&a, 0, sizeof a);
    a.sa_handler = caught;
    sigemptyset(&a.sa_mask);
    a.sa_flags = SA_RESTART;
    uint32_t r = 0;
    size_t n = lean_array_size(sigs);
    for (size_t i = 0; i < n && r == 0; i++) {
        int s = (int)lean_unbox_uint32(lean_array_get_core(sigs, i));
        if (s <= 0 || s >= NSIG || s == SIGKILL || s == SIGSTOP) {
            r = EINVAL;
            break;
        }
        if (change((int)kq, (uintptr_t)s, EVFILT_SIGNAL, EV_ADD, 0, NULL) != 0 || sigaction(s, &a, NULL) != 0)
            r = (uint32_t)errno;
    }
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_next_signal_raw(uint32_t kq) {
    struct kevent e;
    int n = next((int)kq, &e);
    uint64_t r = n < 0                               ? (1ull << 63) | (uint32_t)errno
                 : n != 1 || e.filter != EVFILT_SIGNAL ? (1ull << 63) | EINVAL
                                                     : (uint64_t)(uint32_t)e.ident;
    return lean_io_result_mk_ok(lean_box_uint64(r));
}

LEAN_EXPORT lean_obj_res lean_posix_watch(uint32_t kq, b_lean_obj_arg path, uint32_t tag) {
    uint32_t r;
    int fd = open_events(lean_string_cstr(path));
    if (fd < 0) r = 0x80000000u | (uint32_t)errno;
    else if (change((int)kq, (uintptr_t)fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
                    NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_RENAME, (void *)(uintptr_t)tag) != 0) {
        r = 0x80000000u | (uint32_t)errno;
        close(fd);
    } else r = (uint32_t)fd;
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

/* An event's bit in `kqWait`'s result. */
static uint32_t bit(const struct kevent *e) {
    return e->filter == EVFILT_READ     ? 1
           : e->filter == EVFILT_SIGNAL ? 2
           : e->filter == EVFILT_PROC   ? 16
           : e->udata                   ? 8
                                        : 4;
}

LEAN_EXPORT lean_obj_res lean_posix_kq_wait_until(uint32_t kq, uint8_t forever, uint32_t ms) {
    struct kevent e[64];
    struct timespec ts = {0, 0};
    uint64_t end = forever ? 0 : clock_gettime_nsec_np(CLOCK_MONOTONIC) + (uint64_t)ms * 1000000ull;
    int n;
    for (;;) {
        uint64_t left = 1;
        if (!forever) {
            uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            left = now < end ? end - now : 0;
            ts.tv_sec = (time_t)(left / 1000000000ull);
            ts.tv_nsec = (long)(left % 1000000000ull);
        }
        n = kevent((int)kq, NULL, 0, e, 64, forever ? NULL : &ts);
        if (n >= 0 || errno != EINTR) break;
        if (left == 0) {
            n = 0;
            break;
        }
    }
    uint32_t m = n < 0 ? 0x80000000u : 0;
    lean_object *fds = lean_mk_empty_array();
    lean_object *pids = lean_mk_empty_array();
    for (int i = 0; i < n; i++) {
        uint32_t b = bit(&e[i]);
        m |= b;
        if (b == 4) fds = lean_array_push(fds, lean_box_uint32((uint32_t)e[i].ident));
        if (b == 16) pids = lean_array_push(pids, lean_box_uint32((uint32_t)e[i].ident));
    }
    lean_object *q = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(q, 0, fds);
    lean_ctor_set(q, 1, pids);
    lean_object *p = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(p, 0, lean_box_uint32(m));
    lean_ctor_set(p, 1, q);
    return lean_io_result_mk_ok(p);
}

LEAN_EXPORT lean_obj_res lean_posix_watch_exit(uint32_t kq, uint32_t pid) {
    uint32_t r = change((int)kq, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, NULL) != 0 ? (uint32_t)errno : 0;
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_unwatch_exit(uint32_t kq, uint32_t pid) {
    change((int)kq, pid, EVFILT_PROC, EV_DELETE, 0, NULL);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_await_exits(uint32_t kq, uint32_t n) {
    struct kevent e[64];
    uint32_t left = n, r = 0;
    while (left > 0) {
        int got = kevent((int)kq, NULL, 0, e, 64, NULL);
        if (got < 0) {
            if (errno == EINTR) continue;
            r = (uint32_t)errno;
            break;
        }
        left = (uint32_t)got >= left ? 0 : left - (uint32_t)got;
    }
    return lean_io_result_mk_ok(lean_box_uint32(r));
}
