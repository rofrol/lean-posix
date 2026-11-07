import Std.Sync.Mutex
import Posix.Fd

/-!
# Spawning a program that says whether its exec failed

Lean's `IO.Process.spawn` forks, and a child whose `execvp` fails prints "could
not execute external process" and exits 255 (Lean nightly-2026-10-25's
`src/runtime/process.cpp`), so its caller cannot tell a program that did not run
(no file, no execute bit, a script whose interpreter is missing) from one that ran
and died at once. `spawn` reports the exec's own result through a pipe whose write
end closes on exec: the child writes what failed and its errno there, so the
parent reads either that record or the end of the pipe, which the exec closed.

Between `fork` and exec the child calls only async-signal-safe functions
(`fcntl`, `setsid`, `ioctl`, `open`, `dup2`, `close`, `execve`, `write`, `_exit`): another thread
may hold a lock of libc or of Lean's allocator at the fork. So the parent builds
everything first: the program's paths from PATH, as `execvp` would try them
(an empty entry is the current directory; with no PATH, `/usr/bin:/bin`), and
its environment, and the child tries each with `execve`. Unlike `execvp`, a file
the kernel will not execute (ENOEXEC, a script with no `#!`) is not run through
`/bin/sh`: it is a failed exec.

macOS has no `pipe2`, so a pipe is made close-on-exec in a second call, and a
fork in another thread in between gives its child the pipe's ends. Every `pipe`
and `spawn` here holds one lock, so they cannot leak into each other; a fork by
something else (Lean's own spawn) in that window gives its child a copy of the
write end, which delays the end of the pipe until that child exits or execs, as
it would with Lean's spawn.

Signals are left as the parent has them, as Lean's spawn leaves them: Lean
ignores SIGPIPE, and so does the child (`defaultSignals` restores it before an
`exec`). Descriptors the parent has open without close-on-exec stay open in the
child, as with Lean's spawn.

The numbers are macOS's: F_GETFD 1, F_SETFD 2, FD_CLOEXEC 1, F_DUPFD_CLOEXEC 67, O_RDWR 2,
O_CLOEXEC 0x1000000, EINTR 4, ENOENT 2, ENOTDIR 20, EACCES 13, EIO 5, TIOCSCTTY
0x20007461.
-/

namespace Posix

/-- What `spawn` uses for a standard stream the child inherits. -/
def inherit : UInt32 := 0xFFFFFFFF

/-- What `spawn` uses for a standard stream on `/dev/null`, read and written. -/
def devNull : UInt32 := 0xFFFFFFFE

initialize spawnLock : Std.Mutex Unit ← Std.Mutex.new ()

/-- The fork and exec of `spawn`. `paths` are the program's paths to try in order,
`argv` its arguments with its name first, `env` the `NAME=value` entries, of
distinct names, that come before the parent's environment and replace its entries
of the same names; an entry without `=` is a name whose entry the child does not
get. Each of
`stdin`, `stdout` and `stderr` is a descriptor above 2, made the child's 0, 1 or 2,
or `inherit` or `devNull`. The pid; or, with the high bit set, what failed in bits
32 to 39 (0 the exec, 1 opening `/dev/null`, 2 `dup2`, 3 `setsid`, 4 `pipe`, 5
`fork`, 6 a result pipe that failed or gave a record cut short, the child then
killed, 7 `ioctl(TIOCSCTTY)`) and its errno in the low 32 bits. A source descriptor that is not open is
refused at `dup2` before anything is made, so no descriptor made here can take its
number. A child whose setup or exec failed is reaped before this returns. -/
@[extern c inline "({ extern int pipe(int*); extern int fcntl(int, int, ...); extern int fork(void); extern int execve(const char*, char* const*, char* const*); extern int dup2(int, int); extern int setsid(void); extern int open(const char*, int, ...); extern long write(int, const void*, unsigned long); extern long read(int, void*, unsigned long); extern int close(int); extern void _exit(int); extern int waitpid(int, int*, int); extern int* __error(void); extern char** environ; extern int strncmp(const char*, const char*, unsigned long); extern char* strchr(const char*, int); extern unsigned long strlen(const char*); extern int ioctl(int, unsigned long, ...); size_t nc = lean_array_size(#1), na = lean_array_size(#2), ne = lean_array_size(#3), nv = 0; while (environ[nv]) nv++; char** c = malloc((nc + 1) * sizeof(char*)); for (size_t i = 0; i < nc; i++) c[i] = (char*)lean_string_cstr(lean_array_get_core(#1, i)); char** v = malloc((na + 1) * sizeof(char*)); for (size_t i = 0; i < na; i++) v[i] = (char*)lean_string_cstr(lean_array_get_core(#2, i)); v[na] = 0; char** e = malloc((ne + nv + 1) * sizeof(char*)); size_t k = 0; for (size_t i = 0; i < ne; i++) { const char* x = lean_string_cstr(lean_array_get_core(#3, i)); if (strchr(x, '=')) e[k++] = (char*)x; } for (size_t j = 0; j < nv; j++) { int keep = 1; for (size_t i = 0; i < ne; i++) { const char* x = lean_string_cstr(lean_array_get_core(#3, i)); const char* q = strchr(x, '='); unsigned long n = q ? (unsigned long)(q - x) : strlen(x); if (strncmp(environ[j], x, n) == 0 && environ[j][n] == '=') { keep = 0; break; } } if (keep) e[k++] = environ[j]; } e[k] = 0; int fds[3] = {(int)#4, (int)#5, (int)#6}; uint64_t res = 0; for (int i = 0; i < 3; i++) if (fds[i] >= 0 && fcntl(fds[i], 1) < 0) { res = (1ULL << 63) | (2ULL << 32) | (unsigned)*__error(); break; } int p[2]; if (res) {} else if (pipe(p) != 0) res = (1ULL << 63) | (4ULL << 32) | (unsigned)*__error(); else { fcntl(p[0], 2, 1); fcntl(p[1], 2, 1); if (p[1] < 3) { int d = fcntl(p[1], 67, 3); int x = *__error(); close(p[1]); p[1] = d; if (d < 0) { close(p[0]); res = (1ULL << 63) | (4ULL << 32) | (unsigned)x; } } } if (res) {} else { int pid = fork(); if (pid == 0) { int st = 0, er = 0, w = p[1], r; if (#7 && setsid() < 0) { st = 3; er = *__error(); } for (int i = 0; st == 0 && i < 3; i++) { int fd = fds[i]; if (fd == -1) continue; int opened = 0; if (fd == -2) { fd = open(\"/dev/null\", 2 | 0x1000000); if (fd < 0) { st = 1; er = *__error(); break; } opened = fd != i; } if (fd == i) r = fcntl(i, 2, 0); else do r = dup2(fd, i); while (r < 0 && *__error() == 4); if (r < 0) { st = 2; er = *__error(); } if (opened) close(fd); } if (st == 0 && #8 && ioctl(0, 0x20007461UL, 0) < 0) { st = 7; er = *__error(); } if (st == 0) { int seen = 0, stop = 0; for (size_t i = 0; i < nc && !stop; i++) { execve(c[i], v, e); int x = *__error(); if (x == 13) seen = 1; else if (x != 2 && x != 20) { er = x; stop = 1; } } if (!stop) er = seen ? 13 : 2; } int rec[2] = {st, er}; long put = 0; while (put < 8) { long n = write(w, (char*)rec + put, 8 - put); if (n > 0) put += n; else if (n < 0 && *__error() == 4) continue; else break; } _exit(127); } int forkErr = *__error(); close(p[1]); if (pid < 0) { res = (1ULL << 63) | (5ULL << 32) | (unsigned)forkErr; close(p[0]); } else { int rec[2]; long got = 0; int rerr = 0; while (got < 8) { long r = read(p[0], (char*)rec + got, 8 - got); if (r > 0) got += r; else if (r < 0 && *__error() == 4) continue; else { if (r < 0) rerr = *__error(); break; } } close(p[0]); if (got == 0 && !rerr) res = (uint64_t)(unsigned)pid; else { extern int kill(int, int); int s; if (got != 8) kill(pid, 9); while (waitpid(pid, &s, 0) < 0 && *__error() == 4) {} res = got == 8 ? (1ULL << 63) | ((uint64_t)(rec[0] & 0xff) << 32) | (unsigned)rec[1] : (1ULL << 63) | (6ULL << 32) | (unsigned)(rerr ? rerr : 5); } } } free(c); free(v); free(e); lean_io_result_mk_ok(lean_box_uint64(res)); })"]
opaque spawnRaw (paths argv env : @& Array String) (stdin stdout stderr : UInt32) (setsid ctty : Bool) : IO UInt64

/-- The paths `execvp` would try for `name`, from `path`, the value of PATH. -/
def candidates (name : String) (path : Option String) : Array String :=
  if name.isEmpty then #[]
  else if name.contains '/' then #[name]
  else ((path.getD "/usr/bin:/bin").splitOn ":").toArray.map fun d =>
    (if d.isEmpty then "." else d) ++ "/" ++ name

/-- Why `spawn` started no program: what failed, and its errno. -/
structure SpawnFailure where
  /-- `exec` when the program could not be executed; otherwise the step of the
  setup before it that failed: `open /dev/null`, `dup2`, `setsid`, `TIOCSCTTY`,
  `pipe`, `fork`, or `the result pipe` for a record cut short. -/
  stage : String
  errno : UInt32
  deriving Repr, BEq

def SpawnFailure.ofStage : UInt32 → String
  | 0 => "exec"
  | 1 => "open /dev/null"
  | 2 => "dup2"
  | 3 => "setsid"
  | 4 => "pipe"
  | 5 => "fork"
  | 7 => "TIOCSCTTY"
  | _ => "the result pipe"

/-- Starts `argv` (its first word the program, looked up on PATH as `execvp` does
unless it holds a `/`) with the parent's environment, `env`'s `NAME=value` entries
(of distinct names) replacing the entries of their names, an entry `NAME` without
`=` removing that name's, and `stdin`, `stdout` and `stderr` each a
descriptor above 2 that becomes the child's own, `inherit` or `devNull`; in a
session of its own, leading its process group, with `setsid`; with `ctty` too, its
stdin, which must then be a terminal no session controls, becomes its controlling
terminal (`TIOCSCTTY`), so it gets SIGWINCH when the terminal's size is set, as
`login_tty` does. The child's pid once
the program runs: the exec has succeeded by then. Or why no program runs, the child
being reaped already. The caller's descriptors stay open and its own: close the
child's ends after the spawn, whatever its result. The pid is the caller's to reap
(`waitpid`), once. Throws, starting nothing, when a descriptor is 0, 1 or 2, which
the child's own setup would overwrite. -/
def trySpawn (argv : Array String) (env : Array String := #[]) (stdin stdout stderr : UInt32 := inherit)
    (setsid ctty := false) : IO (Except SpawnFailure UInt32) := do
  for fd in [stdin, stdout, stderr] do
    unless fd == inherit || fd == devNull || fd > 2 do
      throw (IO.userError s!"Posix.spawn: descriptor {fd} is one of the child's 0, 1 and 2: give inherit")
  let paths := candidates (argv[0]?.getD "") (← IO.getEnv "PATH")
  let r ← spawnLock.atomically do spawnRaw paths argv env stdin stdout stderr setsid ctty
  if r >>> 63 == 0 then return .ok r.toUInt32
  return .error { stage := SpawnFailure.ofStage ((r >>> 32) &&& 0xff).toUInt32, errno := r.toUInt32 }

/-- `trySpawn`, throwing why no program runs: `cannot execute NAME: REASON`, or
`cannot start NAME: STAGE: REASON` for a failure of the setup before the exec. -/
def spawn (argv : Array String) (env : Array String := #[]) (stdin stdout stderr : UInt32 := inherit)
    (setsid ctty := false) : IO UInt32 := do
  match ← trySpawn argv env stdin stdout stderr setsid ctty with
  | .ok pid => return pid
  | .error f =>
    let name := argv[0]?.getD ""
    let why ← strerror f.errno
    throw (IO.userError (if f.stage == "exec" then s!"cannot execute {name}: {why}"
      else s!"cannot start {name}: {f.stage}: {why}"))

@[extern c inline "({ extern int pipe(int*); extern int fcntl(int, int, ...); extern int* __error(void); int p[2]; uint64_t r; if (pipe(p) != 0) r = (1ULL << 63) | (unsigned)*__error(); else { fcntl(p[0], 2, 1); fcntl(p[1], 2, 1); r = (uint64_t)(unsigned)p[0] | ((uint64_t)(unsigned)p[1] << 32); } lean_io_result_mk_ok(lean_box_uint64(r)); })"]
private opaque pipeRaw : IO UInt64

/-- A pipe, its read end and its write end, both close-on-exec: `spawn` makes the
one given to a child its own 0, 1 or 2. Under `spawn`'s lock, so no spawn here
leaks it. -/
def pipe : IO (UInt32 × UInt32) := do
  let r ← spawnLock.atomically do pipeRaw
  if r >>> 63 != 0 then throw (IO.userError s!"pipe: {← strerror r.toUInt32}")
  return (r.toUInt32, (r >>> 32).toUInt32)

/-- Waits for the child `pid` to exit and reaps it, past any EINTR: its exit status,
or 128 plus the signal that ended it, as Lean's `Child.wait` gives them. Throws when
`pid` is no child of this process to wait for. -/
@[extern c inline "({ extern int waitpid(int, int*, int); extern int* __error(void); int s = 0, r; do r = waitpid((int)#1, &s, 0); while (r < 0 && *__error() == 4); r < 0 ? lean_io_result_mk_error(lean_decode_io_error(*__error(), NULL)) : lean_io_result_mk_ok(lean_box_uint32((s & 0x7f) == 0 ? (unsigned)((s >> 8) & 0xff) : 128u + (unsigned)(s & 0x7f))); })"]
opaque waitpid (pid : UInt32) : IO UInt32

/-- Writes all of `bytes` to `fd`, past any EINTR and short write: 0, or the errno of
the write that failed (EPIPE when the reader is gone, as Lean ignores SIGPIPE). -/
@[extern c inline "({ extern long write(int, const void*, unsigned long); extern int* __error(void); size_t n = lean_sarray_size(#2), got = 0; unsigned e = 0; while (got < n) { long r = write((int)#1, lean_sarray_cptr(#2) + got, n - got); if (r > 0) got += (size_t)r; else if (r < 0 && *__error() == 4) continue; else { e = r < 0 ? (unsigned)*__error() : 5u; break; } } lean_io_result_mk_ok(lean_box_uint32(e)); })"]
opaque writeAll (fd : UInt32) (bytes : @& ByteArray) : IO UInt32

end Posix
