/*
 * The pipe, wait and write bindings of Posix/Spawn.lean, whose doc comments
 * are the contract: every constant and wait-status macro comes from the SDK's
 * headers. `spawnRaw` stays an inline expression there until it is rewritten
 * on `posix_spawn`.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <lean/lean.h>

/* Both ends close-on-exec, the read end in the low 32 bits; or the high bit
   or-ed with the errno. */
LEAN_EXPORT lean_obj_res lean_posix_pipe_raw(void) {
    int p[2];
    uint64_t r;
    if (pipe(p) != 0) {
        r = (1ULL << 63) | (uint32_t)errno;
    } else {
        fcntl(p[0], F_SETFD, FD_CLOEXEC);
        fcntl(p[1], F_SETFD, FD_CLOEXEC);
        r = (uint64_t)(uint32_t)p[0] | ((uint64_t)(uint32_t)p[1] << 32);
    }
    return lean_io_result_mk_ok(lean_box_uint64(r));
}

LEAN_EXPORT lean_obj_res lean_posix_waitpid(uint32_t pid) {
    int s = 0, r;
    do r = waitpid((pid_t)pid, &s, 0);
    while (r < 0 && errno == EINTR);
    if (r < 0) return lean_io_result_mk_error(lean_decode_io_error(errno, NULL));
    /* A stop report (traced child) has no exit status: its low 7 bits, 0x7f,
       come back as the signal, 128 + 127, as before. */
    uint32_t v = WIFEXITED(s) ? (uint32_t)WEXITSTATUS(s) : 128u + (uint32_t)(s & 0x7f);
    return lean_io_result_mk_ok(lean_box_uint32(v));
}

/* The raw status of the child's end: a stop or continue report (low 7 bits
   _WSTOPPED) is passed by and the wait goes on. */
LEAN_EXPORT lean_obj_res lean_posix_wait_status(uint32_t pid) {
    int s = 0, r;
    do r = waitpid((pid_t)pid, &s, 0);
    while ((r < 0 && errno == EINTR) || (r >= 0 && (WIFSTOPPED(s) || WIFCONTINUED(s))));
    if (r < 0) return lean_io_result_mk_error(lean_decode_io_error(errno, NULL));
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)s));
}

LEAN_EXPORT lean_obj_res lean_posix_write_all(uint32_t fd, b_lean_obj_arg bytes) {
    size_t n = lean_sarray_size(bytes), got = 0;
    uint32_t e = 0;
    while (got < n) {
        ssize_t r = write((int)fd, lean_sarray_cptr(bytes) + got, n - got);
        if (r > 0) got += (size_t)r;
        else if (r < 0 && errno == EINTR) continue;
        else {
            e = r < 0 ? (uint32_t)errno : EIO;
            break;
        }
    }
    return lean_io_result_mk_ok(lean_box_uint32(e));
}
