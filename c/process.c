/*
 * The process bindings of Posix/Process.lean, whose doc comments are the
 * contract: `struct proc_bsdinfo`, `struct rusage` and every constant come
 * from the SDK's headers.
 */
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <unistd.h>

#include <lean/lean.h>

LEAN_EXPORT lean_obj_res lean_posix_exec(b_lean_obj_arg argv, b_lean_obj_arg what) {
    size_t n = lean_array_size(argv);
    char **v = malloc((n + 1) * sizeof(char *));
    for (size_t i = 0; i < n; i++) v[i] = (char *)lean_string_cstr(lean_array_get_core(argv, i));
    v[n] = NULL;
    execvp(v[0], v);
    perror(lean_string_cstr(what));
    free(v);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_exec_resume(b_lean_obj_arg path) {
    const char *p = lean_string_cstr(path);
    char *const a[] = {(char *)p, "--resume", NULL};
    execv(p, a);
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)errno));
}

LEAN_EXPORT lean_obj_res lean_posix_kill_now(int32_t pid) {
    kill((pid_t)pid, SIGKILL);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_kill(int32_t pid, uint32_t sig) {
    uint32_t r = kill((pid_t)pid, (int)sig) == 0 ? 0 : (uint32_t)errno;
    return lean_io_result_mk_ok(lean_box_uint32(r));
}

LEAN_EXPORT lean_obj_res lean_posix_alarm(uint32_t seconds) {
    alarm(seconds); /* delay: external deadline: the caller's own, given in seconds */
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_default_signals(void) {
    static const int sigs[] = {SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGTSTP};
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) signal(sigs[i], SIG_DFL);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_default_pipe(void) {
    signal(SIGPIPE, SIG_DFL);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_posix_process_start_raw(uint32_t pid) {
    struct proc_bsdinfo info;
    uint64_t r;
    if (proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) == (int)sizeof info)
        r = info.pbi_start_tvsec * 1000000ull + info.pbi_start_tvusec;
    else {
        int e = errno;
        r = (1ull << 63) | (uint64_t)(e != 0 ? e : EIO);
    }
    return lean_io_result_mk_ok(lean_box_uint64(r));
}

LEAN_EXPORT lean_obj_res lean_posix_peak_rss(void) {
    struct rusage ru = {0};
    getrusage(RUSAGE_SELF, &ru);
    return lean_io_result_mk_ok(lean_box_usize((size_t)ru.ru_maxrss));
}

/* Every pid the system has now, in `*out` (malloc'd, the caller frees it):
   their number, or -1 with errno. proc_listallpids takes the buffer's size in
   bytes and gives the number of pids it filled; a buffer it fills is grown
   and the call made again, as processes may have been made meanwhile. */
static int all_pids(pid_t **out) {
    int n = proc_listallpids(NULL, 0);
    if (n < 0) return -1;
    for (int cap = n * 2 + 64, tries = 0; tries < 16; cap *= 2, tries++) {
        pid_t *b = malloc((size_t)cap * sizeof(pid_t));
        if (!b) lean_internal_panic_out_of_memory();
        int got = proc_listallpids(b, cap * (int)sizeof(pid_t));
        if (got < 0) {
            int e = errno;
            free(b);
            errno = e;
            return -1;
        }
        if (got < cap) {
            *out = b;
            return got;
        }
        free(b);
    }
    errno = EAGAIN;
    return -1;
}

/* The live processes of session `sid` but the caller and the `nskip` pids of
   `skip`, in `*out` (malloc'd): their number, or -1 with errno. getsid fails
   with ESRCH for a process that has exited (a zombie included), which is no
   member; any other failure of it fails the whole listing. */
static int members(pid_t sid, const pid_t *skip, size_t nskip, pid_t **out) {
    pid_t *all;
    int n = all_pids(&all);
    if (n < 0) return -1;
    pid_t self = getpid();
    int k = 0;
    for (int i = 0; i < n; i++) {
        pid_t p = all[i];
        if (p <= 0 || p == self) continue;
        int skipped = 0;
        for (size_t j = 0; j < nskip && !skipped; j++) skipped = skip[j] == p;
        if (skipped) continue;
        pid_t s = getsid(p);
        if (s < 0 && errno == ESRCH) continue;
        if (s < 0) {
            int e = errno;
            free(all);
            errno = e;
            return -1;
        }
        if (s == sid) all[k++] = p;
    }
    *out = all;
    return k;
}

static lean_object *except_error(uint32_t e) {
    lean_object *r = lean_alloc_ctor(0, 1, 0);
    lean_ctor_set(r, 0, lean_box_uint32(e));
    return r;
}

static lean_object *except_ok(lean_object *v) {
    lean_object *r = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(r, 0, v);
    return r;
}

static lean_object *pid_array(const pid_t *p, size_t n) {
    lean_object *a = lean_alloc_array(n, n);
    for (size_t i = 0; i < n; i++) lean_array_set_core(a, i, lean_box_uint32((uint32_t)p[i]));
    return a;
}

/* A session no caller may name: 0 and 1 (launchd's), and the caller's own. */
static int forbidden_session(uint32_t sid) {
    return sid <= 1 || sid > (uint32_t)INT32_MAX || getsid(0) == (pid_t)sid;
}

/* `Except UInt32 (Array UInt32)`. */
LEAN_EXPORT lean_obj_res lean_posix_session_members(uint32_t sid) {
    if (sid == 0 || sid > (uint32_t)INT32_MAX) return lean_io_result_mk_ok(except_error(EINVAL));
    pid_t *m;
    int n = members((pid_t)sid, NULL, 0, &m);
    if (n < 0) return lean_io_result_mk_ok(except_error((uint32_t)errno));
    lean_object *a = pid_array(m, (size_t)n);
    free(m);
    return lean_io_result_mk_ok(except_ok(a));
}

/* Drops the watch of `pid` on `kq`; an exit it queued already stays queued,
   and the round's wait passes it by. */
static void unwatch(int kq, pid_t pid) {
    struct kevent c;
    EV_SET(&c, (uintptr_t)pid, EVFILT_PROC, EV_DELETE, 0, 0, NULL);
    kevent(kq, &c, 1, NULL, 0, NULL);
}

/* One round of `killSession` over the members `m`: each one's exit is watched
   on a new kqueue first, then its session is read again (so the process the
   watch holds is a member), then SIGKILL is sent; the round blocks until every
   process it killed has exited, counting each one's exit once and no other
   event. A pid whose watch fails with ESRCH has exited already and gets no
   signal. A kill refused with another errno than ESRCH adds the pid and the
   errno to `refused`. The number of processes killed, or -1 with errno when
   the kqueue or a watch fails otherwise; no member whose watch failed is
   signalled. */
static int kill_round(pid_t sid, const pid_t *m, int n, pid_t *refused, int *errs, size_t *nref) {
    int kq = kqueue();
    if (kq < 0) return -1;
    /* 1 for each member whose exit the round still waits for. */
    char *awaited = calloc((size_t)n + 1, 1);
    if (!awaited) lean_internal_panic_out_of_memory();
    int killed = 0, waiting = 0, failed = 0;
    for (int i = 0; i < n && !failed; i++) {
        struct kevent c, r;
        EV_SET(&c, (uintptr_t)m[i], EVFILT_PROC, EV_ADD | EV_RECEIPT, NOTE_EXIT, 0, NULL);
        int got;
        do got = kevent(kq, &c, 1, &r, 1, NULL);
        while (got < 0 && errno == EINTR);
        if (got < 0) failed = errno;
        else if (got != 1 || !(r.flags & EV_ERROR)) failed = EIO;
        else if (r.data == ESRCH) continue;
        else if (r.data != 0) failed = (int)r.data;
        if (failed) break;
        if (getsid(m[i]) != sid) {
            /* Gone, or the pid is another process's now: not a member. */
            unwatch(kq, m[i]);
            continue;
        }
        if (kill(m[i], SIGKILL) == 0) {
            killed++;
            awaited[i] = 1;
            waiting++;
        } else if (errno == ESRCH) {
            /* Exited between the check and the kill: its watch fires. */
            awaited[i] = 1;
            waiting++;
        } else {
            refused[*nref] = m[i];
            errs[(*nref)++] = errno;
            unwatch(kq, m[i]);
        }
    }
    while (waiting > 0 && !failed) {
        struct kevent e[64];
        int got = kevent(kq, NULL, 0, e, 64, NULL);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) {
            failed = errno;
            break;
        }
        for (int j = 0; j < got; j++) {
            if (e[j].filter != EVFILT_PROC || !(e[j].fflags & NOTE_EXIT)) continue;
            for (int i = 0; i < n; i++)
                if (awaited[i] && (uintptr_t)m[i] == e[j].ident) {
                    awaited[i] = 0;
                    waiting--;
                    break;
                }
        }
    }
    free(awaited);
    close(kq);
    if (failed) {
        errno = failed;
        return -1;
    }
    return killed;
}

/* `killSession`'s raw result: `Except UInt32 (UInt32 × Array UInt64 × Array
   UInt32)`, the number killed, each refused pid in the low 32 bits with its
   errno above, and the members left after the last round. */
LEAN_EXPORT lean_obj_res lean_posix_kill_session_raw(uint32_t sid, uint32_t rounds) {
    if (forbidden_session(sid)) return lean_io_result_mk_ok(except_error(EINVAL));
    size_t cap = 64, nref = 0;
    pid_t *refused = malloc(cap * sizeof(pid_t));
    int *errs = malloc(cap * sizeof(int));
    if (!refused || !errs) lean_internal_panic_out_of_memory();
    uint32_t killed = 0;
    pid_t *m = NULL;
    int n = 0, failed = 0;
    for (uint32_t round = 0;; round++) {
        n = members((pid_t)sid, refused, nref, &m);
        if (n < 0) {
            failed = errno;
            break;
        }
        if (n == 0 || round == rounds) break;
        if (nref + (size_t)n > cap) {
            while (nref + (size_t)n > cap) cap *= 2;
            refused = realloc(refused, cap * sizeof(pid_t));
            errs = realloc(errs, cap * sizeof(int));
            if (!refused || !errs) lean_internal_panic_out_of_memory();
        }
        int k = kill_round((pid_t)sid, m, n, refused, errs, &nref);
        free(m);
        m = NULL;
        if (k < 0) {
            failed = errno;
            break;
        }
        killed += (uint32_t)k;
    }
    lean_object *res;
    if (failed) res = except_error((uint32_t)failed);
    else {
        lean_object *ref = lean_alloc_array(nref, nref);
        for (size_t i = 0; i < nref; i++)
            lean_array_set_core(ref, i, lean_box_uint64((uint64_t)(uint32_t)refused[i] | ((uint64_t)(uint32_t)errs[i] << 32)));
        lean_object *t = lean_alloc_ctor(0, 2, 0);
        lean_ctor_set(t, 0, ref);
        lean_ctor_set(t, 1, pid_array(m, (size_t)n));
        lean_object *p = lean_alloc_ctor(0, 2, 0);
        lean_ctor_set(p, 0, lean_box_uint32(killed));
        lean_ctor_set(p, 1, t);
        res = except_ok(p);
    }
    free(m);
    free(refused);
    free(errs);
    return lean_io_result_mk_ok(res);
}
