/*
 * The lock and link bindings of Posix/Lock.lean, whose doc comments are the
 * contract: `struct stat` and every constant come from the SDK's headers.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <lean/lean.h>

/* `flock(fd, op)`, asked again after each EINTR: flock's result. */
static int lock(int fd, int op) {
    int k;
    do k = flock(fd, op);
    while (k != 0 && errno == EINTR);
    return k;
}

LEAN_EXPORT lean_obj_res lean_posix_lock_raw(b_lean_obj_arg path, uint8_t block) {
    uint32_t r;
    int fd = open(lean_string_cstr(path), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) r = 0x80000000u | (uint32_t)errno;
    else if (lock(fd, block ? LOCK_EX : LOCK_EX | LOCK_NB) == 0) r = (uint32_t)fd;
    else {
        r = 0x80000000u | (uint32_t)errno;
        close(fd);
    }
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_lock_handed_raw(b_lean_obj_arg path, uint32_t fd32) {
    struct stat a, b;
    uint32_t r;
    int fd = (int)fd32;
    if (fstat(fd, &a) != 0 || stat(lean_string_cstr(path), &b) != 0) r = (uint32_t)errno;
    else if (a.st_dev != b.st_dev || a.st_ino != b.st_ino) r = 0x10000u;
    else if (lock(fd, LOCK_EX | LOCK_NB) != 0) r = (uint32_t)errno;
    else r = fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 ? 0u : (uint32_t)errno;
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_unlock(uint32_t fd) {
    close((int)fd);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_lock_dir(b_lean_obj_arg path) {
    int fd = open(lean_string_cstr(path), O_DIRECTORY | O_CLOEXEC);
    if (fd >= 0 && lock(fd, LOCK_EX) != 0) {
        close(fd);
        fd = -1;
    }
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

LEAN_EXPORT lean_obj_res lean_posix_link(b_lean_obj_arg from, b_lean_obj_arg to) {
    int r = link(lean_string_cstr(from), lean_string_cstr(to));
    return lean_io_result_mk_ok(lean_box_uint32(r == 0 ? 0u : (uint32_t)errno));
}
