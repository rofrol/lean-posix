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
