/*
 * The bindings of Posix/Spawn.lean, whose doc comments are the contract:
 * every constant and wait-status macro comes from the SDK's headers.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* The stages of a failed spawn, as `SpawnFailure.ofStage` decodes them. The
   ctty helper (helper/ctty.c) reports 0, 3 and 7 with the same numbers. */
enum {
    STAGE_EXEC = 0,
    STAGE_DEVNULL = 1,
    STAGE_DUP2 = 2,
    STAGE_PIPE = 4,
    STAGE_RESULT = 6,
    STAGE_HELPER = 8
};

/* The ctty helper's protocol, version 1, which helper/ctty.c speaks too: its
   first argument is the marker, and the first 8 bytes it writes to the result
   pipe are the greeting. A helper of another version refuses the marker and
   writes no greeting. `lake test` spawns through the helper, so a mismatch
   between the two copies fails it. */
#define CTTY_MARKER "--lean-posix-ctty-v1"
#define CTTY_GREETING "lpctty1\n"

static uint64_t failed(int stage, int err) {
    return (1ULL << 63) | ((uint64_t)(stage & 0xff) << 32) | (uint32_t)err;
}

/* `fd`'s file at a descriptor of 3 or above, close-on-exec, `fd` closed; or
   -1 with errno. */
static int above2(int fd) {
    if (fd > 2) return fd;
    int d = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    int e = errno;
    close(fd);
    errno = e;
    return d;
}

/* Reads up to `n` bytes into `buf`, past EINTR and short reads, until the
   pipe's end: the number read, and in `*err` the errno of a read that failed
   (0 at the end). */
static size_t read_upto(int fd, void *buf, size_t n, int *err) {
    size_t got = 0;
    *err = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)buf + got, n - got);
        if (r > 0) got += (size_t)r;
        else if (r < 0 && errno == EINTR) continue;
        else {
            if (r < 0) *err = errno;
            break;
        }
    }
    return got;
}

/* Kills the helper `pid`, unless it has exited already, and reaps it. */
static void kill_and_reap(pid_t pid) {
    int s;
    kill(pid, SIGKILL);
    while (waitpid(pid, &s, 0) < 0 && errno == EINTR) {}
}

/* The ctty spawn: the helper at `helper`, given the child's descriptors and
   environment, does setsid, TIOCSCTTY and the execve along `c`; what it
   reports on the result pipe `p` decides. */
static uint64_t spawn_ctty(const char *helper, posix_spawn_file_actions_t *fa, posix_spawnattr_t *at, int p[2],
                           char **c, size_t nc, char **argv, size_t na, char **env, int setsid_) {
    char wfd[16], count[24];
    snprintf(wfd, sizeof wfd, "%d", p[1]);
    snprintf(count, sizeof count, "%zu", nc);
    char **v = malloc((5 + nc + na + 1) * sizeof(char *));
    if (!v) lean_internal_panic_out_of_memory();
    v[0] = (char *)helper;
    v[1] = CTTY_MARKER;
    v[2] = wfd;
    v[3] = setsid_ ? "1" : "0";
    v[4] = count;
    for (size_t i = 0; i < nc; i++) v[5 + i] = c[i];
    for (size_t i = 0; i < na; i++) v[5 + nc + i] = argv[i];
    v[5 + nc + na] = NULL;
    pid_t pid = 0;
    int r = posix_spawn(&pid, helper, fa, at, v, env);
    free(v);
    close(p[1]);
    if (r != 0) {
        close(p[0]);
        return failed(STAGE_HELPER, r);
    }
    char hello[8];
    int rerr;
    size_t got = read_upto(p[0], hello, sizeof hello, &rerr);
    uint64_t res;
    if (rerr) {
        kill_and_reap(pid);
        res = failed(STAGE_RESULT, rerr);
    } else if (got != 8 || memcmp(hello, CTTY_GREETING, 8) != 0) {
        kill_and_reap(pid);
        res = failed(STAGE_HELPER, EPROTONOSUPPORT);
    } else {
        int rec[2];
        got = read_upto(p[0], rec, sizeof rec, &rerr);
        if (got == 0 && !rerr) res = (uint64_t)(uint32_t)pid;
        else {
            kill_and_reap(pid);
            res = got == 8 ? failed(rec[0], rec[1]) : failed(STAGE_RESULT, rerr ? rerr : EIO);
        }
    }
    close(p[0]);
    return res;
}

/* `spawnRaw` of Posix/Spawn.lean, with the ctty helper's path. With `only`,
   the child gets its 0, 1 and 2 and the descriptors of `keep`, no other
   (POSIX_SPAWN_CLOEXEC_DEFAULT, posix_spawn_file_actions_addinherit_np); the
   parent's own are left as they are, so no copy is made. */
LEAN_EXPORT lean_obj_res lean_posix_spawn(b_lean_obj_arg paths, b_lean_obj_arg argv, b_lean_obj_arg envs,
                                          uint32_t in, uint32_t out, uint32_t err, uint8_t setsid_,
                                          uint8_t ctty, uint8_t only, b_lean_obj_arg keep,
                                          b_lean_obj_arg helper) {
    extern char **environ;
    size_t nc = lean_array_size(paths), na = lean_array_size(argv), ne = lean_array_size(envs), nv = 0;
    while (environ[nv]) nv++;
    char **c = malloc((nc + 1) * sizeof(char *));
    char **v = malloc((na + 1) * sizeof(char *));
    char **e = malloc((ne + nv + 1) * sizeof(char *));
    if (!c || !v || !e) lean_internal_panic_out_of_memory();
    for (size_t i = 0; i < nc; i++) c[i] = (char *)lean_string_cstr(lean_array_get_core(paths, i));
    c[nc] = NULL;
    for (size_t i = 0; i < na; i++) v[i] = (char *)lean_string_cstr(lean_array_get_core(argv, i));
    v[na] = NULL;
    /* env's NAME=value entries first; then the parent's, but for the names env
       holds, with or without a value. */
    size_t k = 0;
    for (size_t i = 0; i < ne; i++) {
        const char *x = lean_string_cstr(lean_array_get_core(envs, i));
        if (strchr(x, '=')) e[k++] = (char *)x;
    }
    for (size_t j = 0; j < nv; j++) {
        int keep = 1;
        for (size_t i = 0; i < ne && keep; i++) {
            const char *x = lean_string_cstr(lean_array_get_core(envs, i));
            const char *q = strchr(x, '=');
            size_t n = q ? (size_t)(q - x) : strlen(x);
            if (strncmp(environ[j], x, n) == 0 && environ[j][n] == '=') keep = 0;
        }
        if (keep) e[k++] = environ[j];
    }
    e[k] = NULL;

    int fds[3] = {(int)in, (int)out, (int)err};
    size_t nk = only ? lean_array_size(keep) : 0;
    int nul = -1, p[2] = {-1, -1}, faInit = 0;
    posix_spawn_file_actions_t fa;
    uint64_t res = 0;
    /* A source or a kept descriptor that is not open is refused before
       anything is made, so that no descriptor made here can take its number. */
    for (int i = 0; i < 3 && !res; i++)
        if (fds[i] >= 0 && fcntl(fds[i], F_GETFD) < 0) res = failed(STAGE_DUP2, errno);
    for (size_t i = 0; i < nk && !res; i++)
        if (fcntl((int)lean_unbox_uint32(lean_array_get_core(keep, i)), F_GETFD) < 0) res = failed(STAGE_DUP2, errno);
    if (!res && (fds[0] == -2 || fds[1] == -2 || fds[2] == -2)) {
        nul = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (nul >= 0) nul = above2(nul);
        if (nul < 0) res = failed(STAGE_DEVNULL, errno);
    }
    if (!res && ctty) {
        if (pipe(p) != 0) res = failed(STAGE_PIPE, errno);
        else {
            fcntl(p[0], F_SETFD, FD_CLOEXEC);
            fcntl(p[1], F_SETFD, FD_CLOEXEC);
            /* Above 2, so that no stream of the child's overwrites it. */
            p[1] = above2(p[1]);
            if (p[1] < 0) {
                res = failed(STAGE_PIPE, errno);
                close(p[0]);
            }
        }
    }
    if (!res) {
        int r = posix_spawn_file_actions_init(&fa);
        if (r != 0) res = failed(STAGE_DUP2, r);
        else faInit = 1;
        for (int i = 0; i < 3 && !res; i++) {
            /* Every source is above 2 (trySpawn refuses 0, 1 and 2; /dev/null
               was moved), so no dup2 here overwrites a later one's source. */
            int src = fds[i] == -2 ? nul : fds[i];
            if (src == -1) continue;
            r = posix_spawn_file_actions_adddup2(&fa, src, i);
            if (r != 0) res = failed(STAGE_DUP2, r);
        }
        if (!res && ctty) {
            /* The helper's end of the result pipe, which it makes close-on-exec again. */
            r = posix_spawn_file_actions_addinherit_np(&fa, p[1]);
            if (r != 0) res = failed(STAGE_DUP2, r);
        }
        /* Under POSIX_SPAWN_CLOEXEC_DEFAULT only what the actions name stays
           open: the 0, 1 and 2 the child inherits as they are (one the parent
           has closed stays closed), and `keep`, close-on-exec cleared in the
           child only. */
        for (int i = 0; i < 3 && only && !res; i++)
            if (fds[i] == -1 && fcntl(i, F_GETFD) >= 0) {
                r = posix_spawn_file_actions_addinherit_np(&fa, i);
                if (r != 0) res = failed(STAGE_DUP2, r);
            }
        for (size_t i = 0; i < nk && !res; i++) {
            r = posix_spawn_file_actions_addinherit_np(&fa, (int)lean_unbox_uint32(lean_array_get_core(keep, i)));
            if (r != 0) res = failed(STAGE_DUP2, r);
        }
        if (res && ctty) {
            close(p[0]);
            close(p[1]);
        }
    }
    posix_spawnattr_t at;
    int atInit = 0;
    if (!res) {
        /* The session is the helper's to make with ctty, after its fork. */
        short flags = (short)((setsid_ && !ctty ? POSIX_SPAWN_SETSID : 0) | (only ? POSIX_SPAWN_CLOEXEC_DEFAULT : 0));
        int r = posix_spawnattr_init(&at);
        if (r == 0) atInit = 1;
        if (r == 0) r = posix_spawnattr_setflags(&at, flags);
        if (r != 0) {
            res = failed(STAGE_EXEC, r);
            if (ctty) {
                close(p[0]);
                close(p[1]);
            }
        }
    }
    if (!res && ctty) {
        res = spawn_ctty(lean_string_cstr(helper), &fa, &at, p, c, nc, v, na, e, setsid_);
    } else if (!res) {
        int r;
        /* Each path in turn, as execvp tries them: one the kernel finds no file
           at is passed by; EACCES is said if some path had a file it would not
           execute and none ran; any other errno ends the search. */
        int seen = 0, stop = 0, er = 0;
        pid_t pid = 0;
        for (size_t i = 0; i < nc && !res && !stop; i++) {
            r = posix_spawn(&pid, c[i], &fa, &at, v, e);
            if (r == 0) res = (uint64_t)(uint32_t)pid;
            else if (r == EACCES) seen = 1;
            else if (r != ENOENT && r != ENOTDIR) {
                er = r;
                stop = 1;
            }
        }
        if (!res) res = failed(STAGE_EXEC, stop ? er : seen ? EACCES : ENOENT);
    }
    if (atInit) posix_spawnattr_destroy(&at);
    if (faInit) posix_spawn_file_actions_destroy(&fa);
    if (nul >= 0) close(nul);
    free(c);
    free(v);
    free(e);
    return lean_io_result_mk_ok(lean_box_uint64(res));
}
