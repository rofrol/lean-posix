import Posix.Fd

/-!
# kqueue: file, process and signal events

Lean's library has no file watching and no process-exit event. These are the two
ways of waiting a program built on this library uses, each one blocking `kevent`:

- a process and its output pipe (`watchSession`, `nextEvent`): its end is the
  process exiting (EVFILT_PROC, NOTE_EXIT), not its output closing, which an orphan
  holding the pipe can put off for ever; and a directory, written to by others;
- stdin, the window size, files and the exits of processes (`kqOpen`, `kqSetup`,
  `watch`, `watchExit`, `kqWait`, `kqWaitFor`), for a full-screen program that
  wakes on events only, or also when a given time has passed;
- the exits of processes that need not be this program's children
  (`watchExits`, `ExitWatch.wait`), which nothing else in Lean or POSIX can wait
  for.
- catchable signals as events (`catchSignals`, `nextSignal`), for a program
  that passes them on to a child instead of dying of them.

macOS's numbers: EVFILT_READ -1, EVFILT_VNODE -4, EVFILT_PROC -5, EVFILT_SIGNAL -6,
EV_ADD 1, EV_DELETE 2, EV_ONESHOT 0x10, EV_CLEAR 0x20, EV_EOF 0x8000, NOTE_DELETE 1,
NOTE_WRITE 2, NOTE_EXTEND 4, NOTE_RENAME 0x20, NOTE_EXIT 0x80000000, SIGWINCH 28,
F_SETFD 2, FD_CLOEXEC 1, F_GETFL 3, F_SETFL 4, O_NONBLOCK 4, O_EVTONLY 0x8000,
O_CLOEXEC 0x1000000, EINTR 4, ESRCH 3, EINVAL 22, CLOCK_MONOTONIC 6, SIGKILL 9, SIGSTOP 17,
NSIG 32, SA_RESTART 2. `struct kevent` and `struct sigaction` (handler, a 32-bit mask,
flags) are declared in each expression as macOS lays them out.
-/

namespace Posix

/-- A descriptor of `path` for its events only, which no child inherits; a large
number when it cannot be opened. -/
@[extern c inline "({ extern int open(const char*, int, ...); lean_io_result_mk_ok(lean_box_uint32((unsigned)open(lean_string_cstr(#1), 0x8000 | 0x1000000))); })"]
opaque openEvents (path : @& String) : IO UInt32

/-- A kqueue, which no child inherits, that reports `fd` readable, `pid`'s exit,
and a write to the directory `dir` (from `openEvents`; none when that failed);
`fd` is made non-blocking. With the high bit set, `pid` had exited already and
only `fd` and `dir` are watched. -/
@[extern c inline "({ extern int kqueue(void); extern int kevent(int, const void*, int, void*, int, const void*); extern int fcntl(int, int, ...); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; }; int kq = kqueue(); fcntl(kq, 2, 1); int fd = (int)#2; fcntl(fd, 4, fcntl(fd, 3) | 4); struct kev r = { (unsigned long)fd, -1, 1, 0, 0, 0 }; kevent(kq, &r, 1, 0, 0, 0); if ((int)#3 >= 0) { struct kev d = { (unsigned long)#3, -4, 1 | 0x20, 2, 0, 0 }; kevent(kq, &d, 1, 0, 0, 0); } struct kev p = { (unsigned long)#1, -5, 1 | 0x10, 0x80000000u, 0, 0 }; unsigned gone = kevent(kq, &p, 1, 0, 0, 0) != 0 ? 0x80000000u : 0; lean_io_result_mk_ok(lean_box_uint32((unsigned)kq | gone)); })"]
opaque watchSession (pid fd dir : UInt32) : IO UInt32

/-- Blocks until the kqueue of `watchSession` has news: 0 the output is readable, 1
the output closed with nothing left in it, 2 the process exited (or the kqueue
failed, which ends the wait all the same), 3 the directory was written to. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; } e; int n; do n = kevent((int)#1, 0, 0, &e, 1, 0); while (n < 0 && *__error() == 4); unsigned r = n != 1 || e.filter == -5 ? 2 : e.filter == -4 ? 3 : (e.flags & 0x8000) && e.data == 0 ? 1 : 0; lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque nextEvent (kq : UInt32) : IO UInt32

/-- Stops reporting `fd`, whose writers are all gone. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; } r = { (unsigned long)#2, -1, 2, 0, 0, 0 }; kevent((int)#1, &r, 1, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque unwatchRead (kq fd : UInt32) : IO Unit

/-- A kqueue that no child inherits. -/
@[extern c inline "({ extern int kqueue(void); extern int fcntl(int, int, ...); int k = kqueue(); fcntl(k, 2, 1); lean_io_result_mk_ok(lean_box_uint32((unsigned)k)); })"]
opaque kqOpen : IO UInt32

/-- Watches stdin for input and SIGWINCH, which is ignored by default and still
reaches the kqueue. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c[2] = {{0, -1, 1, 0, 0, 0}, {28, -6, 1, 0, 0, 0}}; kevent((int)#1, c, 2, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque kqSetup (kq : UInt32) : IO Unit

/-- The handler `catchSignals` installs: it does nothing. Its C name is what that
installs; with an unboxed argument and result it is a plain C function that touches
no Lean object, so it is safe in a signal handler. It is called through a
`void (*)(int)`, as `termCtl` is: the argument comes in the same register and the
result is dropped on arm64 and x86_64 macOS. -/
@[noinline, export lean_posix_signal_caught]
private def signalCaught (sig : UInt32) : UInt32 := sig

/-- Watches the signals `sigs` on `kq` and catches each with a handler that does
nothing, so that it no longer ends, stops or is ignored by this process but arrives
on `kq` (EVFILT_SIGNAL): 0, or the errno of the first signal that failed, those
before it watched and caught (EINVAL (22) for SIGKILL, SIGSTOP or a number that is
no signal). Each is watched on `kq` before it is caught, so one that comes in
between still has the effect it had before the call (its default, unless the
program changed it), never a lost event. `nextSignal` reads them; `kqWait` would report
any of them as bit 2, a new window size, so give them a kqueue of their own (from
`kqOpen`) when the program also uses `kqWait`.

Caught, not ignored: an ignored signal stays ignored across exec, so a child
started afterwards (by `spawn`, `trySpawn`, Lean's spawn, `posix_spawn`) would not
die of SIGINT on Ctrl-C; exec resets a caught signal to its default, so the program
the child executes gets SIGHUP, SIGINT, SIGTERM and the others with their default
effect. The signal mask is not changed, and a kqueue is not inherited. Between
`fork` and exec, `trySpawn`'s child still has the handler: a signal sent to it in
that window does nothing, and it executes its program all the same.

A wrapper that forwards SIGTERM and SIGHUP to its child calls this before it starts
the child: a signal before the call ends the wrapper while there is no child to
orphan, and one after it reaches `kq`, to be passed on with `kill`. With SIGINT
caught too, a Ctrl-C reaches the child in the same process group and leaves the
wrapper running to reap it. The handlers are process-wide and stay until the
program changes them (`defaultSignals`, `termCtl 1001`). -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int sigaction(int, const void*, void*); extern int* __error(void); extern uint32_t lean_posix_signal_caught(uint32_t); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {0, -6, 1, 0, 0, 0}; struct { void (*h)(int); unsigned m; int f; } a = { (void (*)(int))lean_posix_signal_caught, 0, 0x2 }; unsigned r = 0; size_t n = lean_array_size(#2); for (size_t i = 0; i < n && r == 0; i++) { int s = (int)lean_unbox_uint32(lean_array_get_core(#2, i)); if (s <= 0 || s >= 32 || s == 9 || s == 17) { r = 22; break; } c.id = (unsigned long)s; if (kevent((int)#1, &c, 1, 0, 0, 0) != 0 || sigaction(s, &a, 0) != 0) r = (unsigned)*__error(); } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque catchSignals (kq : UInt32) (sigs : @& Array UInt32) : IO UInt32

/-- `nextSignal`'s result, encoded: the signal's number, or the high bit or-ed with
the errno. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } e; int n; do n = kevent((int)#1, 0, 0, &e, 1, 0); while (n < 0 && *__error() == 4); uint64_t r = n < 0 ? (1ull << 63) | (unsigned)*__error() : n != 1 || e.f != -6 ? (1ull << 63) | 22u : (uint64_t)(unsigned)e.id; lean_io_result_mk_ok(lean_box_uint64(r)); })"]
private opaque nextSignalRaw (kq : UInt32) : IO UInt64

/-- Blocks until a signal watched on `kq` by `catchSignals` arrives, and gives its
number. One signal sent again before it is read comes once (the count is not
kept). Two different signals sent one after the other came in that order (the
test, on macOS 27); macOS's `kevent(2)` promises no order, so no more is claimed. The errno when the wait fails,
or EINVAL (22) when `kq` gave an event that is not a signal's: `kq` holds signal
watches only. -/
def nextSignal (kq : UInt32) : IO (Except UInt32 UInt32) := do
  let r ← nextSignalRaw kq
  return if r &&& ((1 : UInt64) <<< 63) == 0 then .ok r.toUInt32 else .error (r &&& 0xffffffff).toUInt32

/-- Opens `path` for events only and watches it for writes, growth, deletion and
renames, tagged with `tag` (0 or not: `kqWait` tells the two apart); the
descriptor, or 0x80000000 or-ed with the errno when it cannot be opened or
watched. Closing the descriptor ends the watch. -/
@[extern c inline "({ extern int open(const char*, int, ...); extern int kevent(int, const void*, int, void*, int, const void*); extern int close(int); extern int* __error(void); unsigned r; int fd = open(lean_string_cstr(#2), 0x8000 | 0x1000000); if (fd < 0) r = 0x80000000u | (unsigned)*__error(); else { struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)fd, -4, 1 | 0x20, 1 | 2 | 4 | 0x20, 0, (void*)(unsigned long)#3}; if (kevent((int)#1, &c, 1, 0, 0, 0) != 0) { r = 0x80000000u | (unsigned)*__error(); close(fd); } else r = (unsigned)fd; } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque watch (kq : UInt32) (path : @& String) (tag : UInt32) : IO UInt32

/-- The wait of `kqWait` and `kqWaitFor`: with `forever`, until something happens;
otherwise for at most `ms` milliseconds from the call, an interrupted wait
resuming with what is left of them (CLOCK_MONOTONIC), so a signal never stretches
it; one that interrupts the last, zero-length look ends the wait with nothing. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); extern unsigned long long clock_gettime_nsec_np(int); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } e[64]; struct { long s; long ns; } ts = {0, 0}; int forever = #2; unsigned long long end = forever ? 0 : clock_gettime_nsec_np(6) + (unsigned long long)#3 * 1000000ull; int n; for (;;) { unsigned long long left = 1; if (!forever) { unsigned long long now = clock_gettime_nsec_np(6); left = now < end ? end - now : 0; ts.s = (long)(left / 1000000000ull); ts.ns = (long)(left % 1000000000ull); } n = kevent((int)#1, 0, 0, e, 64, forever ? 0 : (const void*)&ts); if (n >= 0 || *__error() != 4) break; if (left == 0) { n = 0; break; } } unsigned m = n < 0 ? 0x80000000u : 0; lean_object* fds = lean_mk_empty_array(); lean_object* pids = lean_mk_empty_array(); for (int i = 0; i < n; i++) { unsigned b = e[i].f == -1 ? 1 : e[i].f == -6 ? 2 : e[i].f == -5 ? 16 : e[i].u ? 8 : 4; m |= b; if (b == 4) fds = lean_array_push(fds, lean_box_uint32((unsigned)e[i].id)); if (b == 16) pids = lean_array_push(pids, lean_box_uint32((unsigned)e[i].id)); } lean_object* q = lean_alloc_ctor(0, 2, 0); lean_ctor_set(q, 0, fds); lean_ctor_set(q, 1, pids); lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32(m)); lean_ctor_set(p, 1, q); lean_io_result_mk_ok(p); })"]
private opaque kqWaitUntil (kq : UInt32) (forever : Bool) (ms : UInt32) :
    IO (UInt32 × Array UInt32 × Array UInt32)

/-- Waits until something happens, or with `poll` only looks at what has: 1 input,
2 a new window size, 4 a file watched with tag 0 changed, 8 one with another tag
changed, 16 a process watched on it with `watchExit` exited, or-ed, 0x80000000
when the wait fails; the descriptors of the files of tag 0 that changed; and the
pids of the processes that exited. At most 64 events a call; the rest wait for the
next. -/
def kqWait (kq : UInt32) (poll : Bool) : IO (UInt32 × Array UInt32 × Array UInt32) :=
  kqWaitUntil kq (!poll) 0

/-- `kqWait` that waits at most `ms` milliseconds: what happened first, as
`kqWait` gives it, or 0 and no descriptors or pids when the time ran out with
nothing happened (every event sets a bit, so 0 is only that). A signal that
interrupts the wait does not lengthen it: it goes on for what is left of `ms`.
`ms` 0 is `kqWait`'s `poll`. -/
def kqWaitFor (kq : UInt32) (ms : UInt32) : IO (UInt32 × Array UInt32 × Array UInt32) :=
  kqWaitUntil kq false ms

/-- Watches the exit of process `pid` on `kq` (from `kqOpen`), once: 0 when it is
watched, ESRCH (3) when no live process has that pid, one that exited and is not
reaped yet included, or the errno of another failure. The watch holds the process,
not its pid: a process that takes the pid after this one exited is not reported. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)#2, -5, 1 | 0x10, 0x80000000u, 0, 0}; unsigned r = kevent((int)#1, &c, 1, 0, 0, 0) != 0 ? (unsigned)*__error() : 0; lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque watchExit (kq pid : UInt32) : IO UInt32

/-- Stops watching the exit of `pid` on `kq`. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)#2, -5, 2, 0, 0, 0}; kevent((int)#1, &c, 1, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque unwatchExit (kq pid : UInt32) : IO Unit

/-- Blocks until `n` exits watched on `kq` have come: 0 then, or the errno of a
failed wait. `kq` holds exit watches only; every event it gives counts as one. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } e[64]; unsigned left = #2, r = 0; while (left > 0) { int n = kevent((int)#1, 0, 0, e, 64, 0); if (n < 0) { if (*__error() == 4) continue; r = (unsigned)*__error(); break; } left = (unsigned)n >= left ? 0 : left - (unsigned)n; } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque awaitExits (kq n : UInt32) : IO UInt32

/-- The exits `watchExits` watches, and what it found of each pid it was given. -/
structure ExitWatch where
  kq : UInt32
  /-- Live when watched; each one's exit is reported once. -/
  watching : Array UInt32
  /-- No live process had the pid: it has exited already, or never was. -/
  gone : Array UInt32
  /-- Not watched, each with the errno of why. -/
  failed : Array (UInt32 × UInt32)

/-- Watches the exits of `pids`, each pid once however often it is given. A kqueue
that cannot be opened fails every pid. -/
def watchExits (pids : Array UInt32) : IO ExitWatch := do
  let kq ← kqOpen
  let mut w : ExitWatch := { kq, watching := #[], gone := #[], failed := #[] }
  for pid in pids do
    if w.watching.contains pid || w.gone.contains pid || w.failed.any (·.1 == pid) then continue
    match ← watchExit kq pid with
    | 0 => w := { w with watching := w.watching.push pid }
    | 3 => w := { w with gone := w.gone.push pid }
    | e => w := { w with failed := w.failed.push (pid, e) }
  return w

/-- Stops watching `pid`, which leaves `watching`. -/
def ExitWatch.forget (w : ExitWatch) (pid : UInt32) : IO ExitWatch := do
  unless w.watching.contains pid do return w
  unwatchExit w.kq pid
  return { w with watching := w.watching.filter (· != pid) }

/-- Blocks until every process in `watching` has exited, then closes the kqueue: 0
when each has, or the errno of a failed wait, after which some may live. -/
def ExitWatch.wait (w : ExitWatch) : IO UInt32 := do
  let r ← if w.watching.isEmpty then pure 0 else awaitExits w.kq w.watching.size.toUInt32
  close w.kq
  return r

end Posix
