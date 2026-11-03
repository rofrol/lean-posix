/-!
# Processes: exec, killing a process or a group, signals, start times, resources

Lean's `IO.Process` spawns and waits; it cannot become another program in the same
process, kill a process group, or put signals back to their defaults. The numbers
are macOS's: SIGHUP 1, SIGINT 2, SIGQUIT 3, SIGKILL 9, SIGPIPE 13, SIGTERM 15,
RUSAGE_SELF 0, PROC_PIDTBSDINFO 3; `struct proc_bsdinfo` is 136 bytes, its
`pbi_start_tvsec` and `pbi_start_tvusec` at 120 and 128.
-/

namespace Posix

/-- Becomes the command `argv` (looked up on `PATH`, `argv[0]` its name), in this
process with this environment. Should that fail it says why after `what` on
stderr, and returns. -/
@[extern c inline "({ extern int execvp(const char*, char* const*); extern void perror(const char*); size_t n = lean_array_size(#1); char** v = malloc((n + 1) * sizeof(char*)); for (size_t i = 0; i < n; i++) v[i] = (char*)lean_string_cstr(lean_array_get_core(#1, i)); v[n] = 0; execvp(v[0], v); perror(lean_string_cstr(#2)); lean_io_result_mk_ok(lean_box(0)); })"]
opaque exec (argv : @& Array String) (what : @& String) : IO Unit

/-- Executes `path` as `path --resume`, in this process, with this environment;
returns only when that fails, with the errno. -/
@[extern c inline "({ extern int execv(const char*, char* const*); extern int* __error(void); const char* a[] = {lean_string_cstr(#1), \"--resume\", 0}; execv(lean_string_cstr(#1), (char* const*)a); lean_io_result_mk_ok(lean_box_uint32((unsigned)*__error())); })"]
opaque execResume (path : @& String) : IO UInt32

/-- SIGKILL to `pid`; `pid` negative is a process group. -/
@[extern c inline "({ extern int kill(int, int); kill((int)#1, 9); lean_io_result_mk_ok(lean_box(0)); })"]
opaque killNow (pid : Int32) : IO Unit

/-- SIGALRM after `seconds`, or none with zero. Its default ends the process. -/
@[extern c inline "({ extern unsigned alarm(unsigned); alarm(#1); lean_io_result_mk_ok(lean_box(0)); })"]
opaque alarm (seconds : UInt32) : IO Unit

/-- The defaults of SIGHUP, SIGINT, SIGQUIT, SIGPIPE and SIGTERM, for a child before
it executes its command: an ignored signal survives exec, and Lean ignores SIGPIPE. -/
@[extern c inline "({ extern void (*signal(int, void (*)(int)))(int); int s[] = {1, 2, 3, 13, 15}; for (int i = 0; i < 5; i++) signal(s[i], 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque defaultSignals : IO Unit

/-- When process `pid` started, in microseconds since the Unix epoch, as macOS's
`proc_pidinfo` (`PROC_PIDTBSDINFO`) gives it, with the high bit clear; or the high
bit or-ed with the errno when it cannot be read (ESRCH: no live process has that
pid). `processStart` gives the two apart. -/
@[extern c inline "({ extern int proc_pidinfo(int, int, unsigned long long, void*, int); extern int* __error(void); unsigned char b[136]; unsigned long long sec, usec; uint64_t r; if (proc_pidinfo((int)#1, 3, 0, b, 136) == 136) { __builtin_memcpy(&sec, b + 120, 8); __builtin_memcpy(&usec, b + 128, 8); r = sec * 1000000ull + usec; } else { int e = *__error(); r = (1ull << 63) | (uint64_t)(e != 0 ? e : 5); } lean_io_result_mk_ok(lean_box_uint64(r)); })"]
opaque processStartRaw (pid : UInt32) : IO UInt64

/-- When process `pid` started, in microseconds since the Unix epoch: a process and
the pid it holds are told from a later one that took the pid by this, as two
processes that held one pid in turn started at different times. The time is set
once, when the process is made, and does not follow the clock after. The errno
when it cannot be read: ESRCH (3) when no live process has the pid, a process that
exited and is not reaped yet included (measured on macOS 27); another one, such as
EPERM, says nothing of whether it lives. -/
def processStart (pid : UInt32) : IO (Except UInt32 Nat) := do
  let r ← processStartRaw pid
  return if r &&& ((1 : UInt64) <<< 63) == 0 then .ok r.toNat else .error (r &&& 0xffffffff).toUInt32

/-- The process's peak resident set, in bytes, as macOS's `getrusage` gives it. -/
@[extern c inline "({ extern int getrusage(int, void*); long r[40]; getrusage(0, r); lean_io_result_mk_ok(lean_box_usize((size_t)r[4])); })"]
opaque peakRss : IO USize

end Posix
