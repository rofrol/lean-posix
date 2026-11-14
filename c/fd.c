/*
 * The descriptor bindings of Posix/Fd.lean, whose doc comments are the
 * contract: `struct stat`, `struct timeval` and every constant come from the
 * SDK's headers.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/filio.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <lean/lean.h>

LEAN_EXPORT lean_obj_res lean_posix_dup2(uint32_t from, uint32_t to) {
    dup2((int)from, (int)to);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_dup_private(uint32_t fd) {
    int d = dup((int)fd);
    fcntl(d, F_SETFD, FD_CLOEXEC);
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)d));
}

LEAN_EXPORT lean_obj_res lean_posix_close(uint32_t fd) {
    close((int)fd);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_read(uint32_t fd, size_t n) {
    lean_object *b = lean_alloc_sarray(1, 0, n);
    ssize_t r;
    do r = read((int)fd, lean_sarray_cptr(b), n);
    while (r < 0 && errno == EINTR);
    lean_sarray_set_size(b, r > 0 ? (size_t)r : 0);
    return lean_io_result_mk_ok(b);
}

LEAN_EXPORT lean_obj_res lean_posix_read_at(b_lean_obj_arg path, uint64_t offset, size_t n) {
    lean_object *b = lean_alloc_sarray(1, 0, n);
    ssize_t r = -1;
    int fd = open(lean_string_cstr(path), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        r = pread(fd, lean_sarray_cptr(b), n, (off_t)offset);
        close(fd);
    }
    lean_sarray_set_size(b, r > 0 ? (size_t)r : 0);
    return lean_io_result_mk_ok(b);
}

static lean_object *pair(lean_object *a, lean_object *b) {
    lean_object *p = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(p, 0, a);
    lean_ctor_set(p, 1, b);
    return p;
}

/* `Except UInt32 (UInt32 × UInt64 × UInt64 × ByteArray)`: `.error` is
 * constructor 0, `.ok` constructor 1. */
LEAN_EXPORT lean_obj_res lean_posix_read_file_at_raw(b_lean_obj_arg path, uint64_t offset, size_t n) {
    struct stat st;
    lean_object *res = NULL;
    uint32_t e = 0;
    int fd = open(lean_string_cstr(path), O_RDONLY | O_CLOEXEC);
    if (fd < 0) e = (uint32_t)errno;
    else if (fstat(fd, &st) != 0) {
        e = (uint32_t)errno;
        close(fd);
    } else {
        lean_object *b = lean_alloc_sarray(1, 0, n);
        ssize_t r = pread(fd, lean_sarray_cptr(b), n, (off_t)offset);
        if (r < 0) {
            e = (uint32_t)errno;
            lean_dec(b);
        }
        close(fd);
        if (r >= 0) {
            lean_sarray_set_size(b, (size_t)r);
            lean_object *p = pair(lean_box_uint32((uint32_t)st.st_dev),
                                  pair(lean_box_uint64((uint64_t)st.st_ino),
                                       pair(lean_box_uint64((uint64_t)st.st_size), b)));
            res = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(res, 0, p);
        }
    }
    if (res == NULL) {
        res = lean_alloc_ctor(0, 1, 0);
        lean_ctor_set(res, 0, lean_box_uint32(e));
    }
    return lean_io_result_mk_ok(res);
}

LEAN_EXPORT lean_obj_res lean_posix_drain_now(uint32_t fd) {
    int n = 0;
    if (ioctl((int)fd, FIONREAD, &n) != 0 || n < 0) n = 0;
    lean_object *b = lean_alloc_sarray(1, 0, (size_t)n);
    ssize_t got = 0;
    while (got < n) {
        ssize_t r = read((int)fd, lean_sarray_cptr(b) + got, (size_t)(n - got));
        if (r > 0) got += r;
        else if (r < 0 && errno == EINTR) continue;
        else break;
    }
    lean_sarray_set_size(b, (size_t)got);
    return lean_io_result_mk_ok(b);
}

LEAN_EXPORT lean_obj_res lean_posix_handle_fd(b_lean_obj_arg h) {
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fileno((FILE *)lean_get_external_data(h))));
}

LEAN_EXPORT lean_obj_res lean_posix_isatty(uint32_t fd) {
    return lean_io_result_mk_ok(lean_box(isatty((int)fd) == 1));
}

LEAN_EXPORT lean_obj_res lean_posix_strerror(uint32_t e) {
    return lean_io_result_mk_ok(lean_mk_string(strerror((int)e)));
}

LEAN_EXPORT lean_obj_res lean_posix_set_times(b_lean_obj_arg path, uint64_t ms) {
    struct timeval v[2];
    v[0].tv_sec = (time_t)(ms / 1000);
    v[0].tv_usec = (suseconds_t)(ms % 1000) * 1000;
    v[1] = v[0];
    return lean_io_result_mk_ok(lean_box_uint32(utimes(lean_string_cstr(path), v) == 0 ? 0u : (uint32_t)errno));
}
